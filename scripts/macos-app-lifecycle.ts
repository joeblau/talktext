type CapturedCommand = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

export type RunningMacApplication = {
  pid: number;
  executablePath: string;
  terminateRequested: boolean;
};

export type MacApplicationSignal = "SIGTERM" | "SIGKILL";

export interface MacApplicationRuntime {
  now(): number;
  sleep(milliseconds: number): Promise<void>;
  requestTermination(bundleIdentifier: string): Promise<RunningMacApplication[]>;
  isSameProcess(application: RunningMacApplication): Promise<boolean>;
  sendSignal(
    application: RunningMacApplication,
    signal: MacApplicationSignal,
  ): Promise<void>;
  runningPIDs(
    executablePath: string,
    executableName: string,
  ): Promise<number[]>;
  open(command: string[]): Promise<CapturedCommand>;
  log(message: string): void;
  warn(message: string): void;
}

export type MacApplicationLifecycleTimings = {
  pollIntervalMs: number;
  gracefulQuitTimeoutMs: number;
  terminateTimeoutMs: number;
  killTimeoutMs: number;
  postQuitSettleMs: number;
  successfulOpenObservationMs: number;
  failedOpenObservationMs: number;
  launchStabilityMs: number;
  launchRetryDelaysMs: number[];
};

const defaultTimings: MacApplicationLifecycleTimings = {
  pollIntervalMs: 100,
  gracefulQuitTimeoutMs: 10_000,
  terminateTimeoutMs: 3_000,
  killTimeoutMs: 2_000,
  // A process can be gone while LaunchServices still points at its dead Apple
  // Event connection. Let that registration settle before asking it to launch
  // the replacement. Retries below cover slower cleanup under load.
  postQuitSettleMs: 400,
  successfulOpenObservationMs: 4_000,
  failedOpenObservationMs: 1_500,
  launchStabilityMs: 600,
  launchRetryDelaysMs: [250, 500, 1_000, 2_000],
};

type StopMacApplicationOptions = {
  bundleIdentifier: string;
  displayName: string;
  timings?: Partial<MacApplicationLifecycleTimings>;
};

type LaunchMacApplicationOptions = {
  appPath: string;
  executablePath: string;
  executableName: string;
  displayName: string;
  environment?: Record<string, string>;
  timings?: Partial<MacApplicationLifecycleTimings>;
};

function timingsWith(
  overrides: Partial<MacApplicationLifecycleTimings> | undefined,
): MacApplicationLifecycleTimings {
  return {
    ...defaultTimings,
    ...overrides,
    launchRetryDelaysMs:
      overrides?.launchRetryDelaysMs ?? defaultTimings.launchRetryDelaysMs,
  };
}

async function capture(command: string[]): Promise<CapturedCommand> {
  const child = Bun.spawn(command, {
    stdin: "ignore",
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdoutPromise = new Response(child.stdout).text();
  const stderrPromise = new Response(child.stderr).text();
  const [exitCode, stdout, stderr] = await Promise.all([
    child.exited,
    stdoutPromise,
    stderrPromise,
  ]);
  return { exitCode, stdout, stderr };
}

function isNoSuchProcess(error: unknown) {
  return (error as { code?: string }).code === "ESRCH";
}

async function commandForPID(pid: number): Promise<string | undefined> {
  const result = await capture([
    "/bin/ps",
    "-ww",
    "-p",
    String(pid),
    "-o",
    "command=",
  ]);
  if (result.exitCode !== 0) {
    return undefined;
  }
  const command = result.stdout.trim();
  return command || undefined;
}

function commandRunsExecutable(command: string, executablePath: string) {
  return command === executablePath || command.startsWith(`${executablePath} `);
}

const systemRuntime: MacApplicationRuntime = {
  now: Date.now,
  sleep: Bun.sleep,

  async requestTermination(bundleIdentifier) {
    // NSRunningApplication selects by exact bundle identifier and requests a
    // normal AppKit termination for every matching instance. This avoids both
    // pgrep name collisions and AppleScript choosing the wrong copy when the
    // development and installed bundles share an identifier.
    const script = `
ObjC.import("AppKit");
const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(${JSON.stringify(bundleIdentifier)}).js;
JSON.stringify(applications.map(application => ({
  pid: Number(application.processIdentifier),
  executablePath: ObjC.unwrap(application.executableURL.path),
  terminateRequested: Boolean(application.terminate)
})));
`;
    const result = await capture([
      "/usr/bin/osascript",
      "-l",
      "JavaScript",
      "-e",
      script,
    ]);
    if (result.exitCode !== 0) {
      const detail = result.stderr.trim() || result.stdout.trim() || "no output";
      throw new Error(
        `Could not inspect running macOS applications (${detail}).`,
      );
    }

    let applications: unknown;
    try {
      applications = JSON.parse(result.stdout.trim() || "[]");
    } catch {
      throw new Error("macOS returned malformed running-application metadata.");
    }
    if (!Array.isArray(applications)) {
      throw new Error("macOS returned invalid running-application metadata.");
    }
    return applications.flatMap((application) => {
      const candidate = application as Partial<RunningMacApplication>;
      if (
        !Number.isInteger(candidate.pid) ||
        (candidate.pid ?? 0) <= 0 ||
        typeof candidate.executablePath !== "string"
      ) {
        return [];
      }
      return [
        {
          pid: candidate.pid as number,
          executablePath: candidate.executablePath,
          terminateRequested: candidate.terminateRequested === true,
        },
      ];
    });
  },

  async isSameProcess(application) {
    const command = await commandForPID(application.pid);
    return command !== undefined &&
      commandRunsExecutable(command, application.executablePath);
  },

  async sendSignal(application, signal) {
    const command = await commandForPID(application.pid);
    if (
      command === undefined ||
      !commandRunsExecutable(command, application.executablePath)
    ) {
      return;
    }
    try {
      process.kill(application.pid, signal);
    } catch (error) {
      if (!isNoSuchProcess(error)) {
        throw error;
      }
    }
  },

  async runningPIDs(executablePath, executableName) {
    const result = await capture([
      "/usr/bin/pgrep",
      "-x",
      executableName,
    ]);
    if (result.exitCode === 1) {
      return [];
    }
    if (result.exitCode !== 0) {
      throw new Error(`Could not inspect running ${executableName} processes.`);
    }

    const candidates = result.stdout
      .split(/\s+/)
      .map((value) => Number(value))
      .filter((pid) => Number.isInteger(pid) && pid > 0);
    const matching = await Promise.all(
      candidates.map(async (pid) => {
        const command = await commandForPID(pid);
        return command !== undefined &&
          commandRunsExecutable(command, executablePath)
          ? pid
          : undefined;
      }),
    );
    return matching.filter((pid): pid is number => pid !== undefined);
  },

  open: capture,
  log: console.log,
  warn: console.warn,
};

async function waitForApplicationsToExit(
  applications: RunningMacApplication[],
  timeoutMs: number,
  timings: MacApplicationLifecycleTimings,
  runtime: MacApplicationRuntime,
) {
  const deadline = runtime.now() + timeoutMs;
  while (true) {
    const states = await Promise.all(
      applications.map((application) => runtime.isSameProcess(application)),
    );
    if (states.every((isRunning) => !isRunning)) {
      return true;
    }
    const remaining = deadline - runtime.now();
    if (remaining <= 0) {
      return false;
    }
    await runtime.sleep(Math.min(timings.pollIntervalMs, remaining));
  }
}

async function remainingApplications(
  applications: RunningMacApplication[],
  runtime: MacApplicationRuntime,
) {
  const states = await Promise.all(
    applications.map((application) => runtime.isSameProcess(application)),
  );
  return applications.filter((_, index) => states[index]);
}

export async function stopMacApplication(
  options: StopMacApplicationOptions,
  runtime: MacApplicationRuntime = systemRuntime,
) {
  const timings = timingsWith(options.timings);
  const applications = await runtime.requestTermination(options.bundleIdentifier);
  if (applications.length === 0) {
    return false;
  }

  runtime.log(`==> Stopping the running ${options.displayName} app...`);
  if (
    await waitForApplicationsToExit(
      applications,
      timings.gracefulQuitTimeoutMs,
      timings,
      runtime,
    )
  ) {
    await runtime.sleep(timings.postQuitSettleMs);
    return true;
  }

  let remaining = await remainingApplications(applications, runtime);
  runtime.warn(
    `warning: ${options.displayName} did not quit normally; sending SIGTERM to ${remaining.map((application) => application.pid).join(", ")}.`,
  );
  await Promise.all(
    remaining.map((application) => runtime.sendSignal(application, "SIGTERM")),
  );
  if (
    await waitForApplicationsToExit(
      remaining,
      timings.terminateTimeoutMs,
      timings,
      runtime,
    )
  ) {
    await runtime.sleep(timings.postQuitSettleMs);
    return true;
  }

  remaining = await remainingApplications(remaining, runtime);
  runtime.warn(
    `warning: ${options.displayName} ignored SIGTERM; sending SIGKILL to ${remaining.map((application) => application.pid).join(", ")}.`,
  );
  await Promise.all(
    remaining.map((application) => runtime.sendSignal(application, "SIGKILL")),
  );
  if (
    !(await waitForApplicationsToExit(
      remaining,
      timings.killTimeoutMs,
      timings,
      runtime,
    ))
  ) {
    const stuck = await remainingApplications(remaining, runtime);
    throw new Error(
      `${options.displayName} processes did not exit: ${stuck.map((application) => application.pid).join(", ")}.`,
    );
  }

  await runtime.sleep(timings.postQuitSettleMs);
  return true;
}

async function waitForStableLaunch(
  executablePath: string,
  executableName: string,
  observationMs: number,
  timings: MacApplicationLifecycleTimings,
  runtime: MacApplicationRuntime,
) {
  const deadline = runtime.now() + observationMs;
  let stableSince: number | undefined;
  let stablePID: number | undefined;

  while (true) {
    const pids = await runtime.runningPIDs(executablePath, executableName);
    if (pids.length > 0) {
      const pid = pids[0];
      if (stablePID !== pid) {
        stablePID = pid;
        stableSince = runtime.now();
      }
      if (
        stableSince !== undefined &&
        runtime.now() - stableSince >= timings.launchStabilityMs
      ) {
        return pid;
      }
    } else {
      stablePID = undefined;
      stableSince = undefined;
    }

    const remaining = deadline - runtime.now();
    if (remaining <= 0) {
      return undefined;
    }
    await runtime.sleep(Math.min(timings.pollIntervalMs, remaining));
  }
}

function oneLineDiagnostic(result: CapturedCommand) {
  const output = `${result.stderr}\n${result.stdout}`
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean)
    .at(-1);
  if (!output) {
    return result.exitCode === 0
      ? "open returned success, but the app did not stay running"
      : `open exited with status ${result.exitCode}`;
  }
  return output.length <= 300 ? output : `${output.slice(0, 297)}...`;
}

export async function launchMacApplication(
  options: LaunchMacApplicationOptions,
  runtime: MacApplicationRuntime = systemRuntime,
) {
  const timings = timingsWith(options.timings);
  const openCommand = ["/usr/bin/open", "-n"];
  for (const [name, value] of Object.entries(options.environment ?? {})) {
    openCommand.push("--env", `${name}=${value}`);
  }
  // Select the exact app bundle instead of opening it as a document through
  // the user's default file handler. No document paths are passed to the app.
  openCommand.push("-a", options.appPath);

  const maximumAttempts = timings.launchRetryDelaysMs.length + 1;
  let lastResult: CapturedCommand | undefined;
  for (let attempt = 1; attempt <= maximumAttempts; attempt += 1) {
    lastResult = await runtime.open(openCommand);
    const observationMs = lastResult.exitCode === 0
      ? timings.successfulOpenObservationMs
      : timings.failedOpenObservationMs;
    const pid = await waitForStableLaunch(
      options.executablePath,
      options.executableName,
      observationMs,
      timings,
      runtime,
    );
    if (pid !== undefined) {
      runtime.log(`==> ${options.displayName} is running (PID ${pid}).`);
      return pid;
    }

    if (attempt === maximumAttempts) {
      break;
    }
    const diagnostic = oneLineDiagnostic(lastResult);
    runtime.warn(
      `warning: macOS did not complete the ${options.displayName} launch (attempt ${attempt}/${maximumAttempts}: ${diagnostic}); retrying...`,
    );
    await runtime.sleep(timings.launchRetryDelaysMs[attempt - 1]);
  }

  const diagnostic = lastResult
    ? oneLineDiagnostic(lastResult)
    : "no launch was attempted";
  throw new Error(
    `macOS could not launch ${options.appPath} after ${maximumAttempts} attempts (${diagnostic}). ` +
      `Inspect recent diagnostics with: /usr/bin/log show --last 5m --predicate 'process == "${options.executableName}"'`,
  );
}
