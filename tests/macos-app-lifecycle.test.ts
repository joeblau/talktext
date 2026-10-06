import { describe, expect, test } from "bun:test";
import {
  launchMacApplication,
  type MacApplicationRuntime,
  type MacApplicationSignal,
  type RunningMacApplication,
  stopMacApplication,
} from "../scripts/macos-app-lifecycle";

const application: RunningMacApplication = {
  pid: 41,
  executablePath: "/fixture/TalkText.app/Contents/MacOS/TalkText",
  terminateRequested: true,
};

function unneeded(): never {
  throw new Error("Unexpected fake-runtime call");
}

describe("macOS application launch lifecycle", () => {
  test("retries a failed LaunchServices handoff and confirms the exact executable", async () => {
    let now = 0;
    let openCount = 0;
    let running = false;
    const commands: string[][] = [];
    const warnings: string[] = [];
    const runtime: MacApplicationRuntime = {
      now: () => now,
      sleep: async (milliseconds) => {
        now += milliseconds;
      },
      requestTermination: async () => unneeded(),
      isSameProcess: async () => unneeded(),
      sendSignal: async () => unneeded(),
      runningPIDs: async (executablePath) => {
        expect(executablePath).toBe(application.executablePath);
        return running ? [52] : [];
      },
      open: async (command) => {
        commands.push(command);
        openCount += 1;
        if (openCount === 1) {
          return {
            exitCode: 1,
            stdout: "",
            stderr: "_LSOpenURLsWithCompletionHandler() failed with error -609.",
          };
        }
        running = true;
        return { exitCode: 0, stdout: "", stderr: "" };
      },
      log: () => {},
      warn: (message) => warnings.push(message),
    };

    const pid = await launchMacApplication(
      {
        appPath: "/fixture/TalkText.app",
        executablePath: application.executablePath,
        executableName: "TalkText",
        displayName: "TalkText",
        environment: { TALKTEXT_DEVELOPMENT_ROOT: "/fixture" },
        timings: {
          pollIntervalMs: 1,
          successfulOpenObservationMs: 3,
          failedOpenObservationMs: 2,
          launchStabilityMs: 1,
          launchRetryDelaysMs: [1],
        },
      },
      runtime,
    );

    expect(pid).toBe(52);
    expect(openCount).toBe(2);
    expect(commands[0]).toEqual([
      "/usr/bin/open",
      "-n",
      "--env",
      "TALKTEXT_DEVELOPMENT_ROOT=/fixture",
      "-a",
      "/fixture/TalkText.app",
    ]);
    expect(warnings[0]).toContain("-609");
  });

  test("accepts a stable launch even when open itself reports a transient error", async () => {
    let now = 0;
    let openCount = 0;
    const runtime: MacApplicationRuntime = {
      now: () => now,
      sleep: async (milliseconds) => {
        now += milliseconds;
      },
      requestTermination: async () => unneeded(),
      isSameProcess: async () => unneeded(),
      sendSignal: async () => unneeded(),
      runningPIDs: async () => [73],
      open: async () => {
        openCount += 1;
        return {
          exitCode: 1,
          stdout: "",
          stderr: "LaunchServices connection invalid (-609)",
        };
      },
      log: () => {},
      warn: () => {},
    };

    const pid = await launchMacApplication(
      {
        appPath: "/fixture/TalkText.app",
        executablePath: application.executablePath,
        executableName: "TalkText",
        displayName: "TalkText",
        timings: {
          pollIntervalMs: 1,
          failedOpenObservationMs: 2,
          launchStabilityMs: 1,
          launchRetryDelaysMs: [1, 1],
        },
      },
      runtime,
    );

    expect(pid).toBe(73);
    expect(openCount).toBe(1);
  });

  test("launches the exact app path without sending it to a default document handler", async () => {
    let now = 0;
    let selectedTalkText = false;
    const appPath = "/fixture with spaces/TalkText.app";
    const executablePath = `${appPath}/Contents/MacOS/TalkText`;
    const runtime: MacApplicationRuntime = {
      now: () => now,
      sleep: async (milliseconds) => {
        now += milliseconds;
      },
      requestTermination: async () => unneeded(),
      isSameProcess: async () => unneeded(),
      sendSignal: async () => unneeded(),
      runningPIDs: async (path) => {
        expect(path).toBe(executablePath);
        return selectedTalkText ? [84] : [];
      },
      open: async (command) => {
        // A successful document open can start another app. Only explicit
        // application selection starts TalkText in this runtime.
        selectedTalkText = command.includes("-a") &&
          command[command.indexOf("-a") + 1] === appPath;
        expect(command).toEqual(["/usr/bin/open", "-n", "-a", appPath]);
        return { exitCode: 0, stdout: "", stderr: "" };
      },
      log: () => {},
      warn: () => {},
    };
    const pid = await launchMacApplication(
      {
        appPath,
        executablePath,
        executableName: "TalkText",
        displayName: "TalkText",
        timings: {
          pollIntervalMs: 1,
          successfulOpenObservationMs: 2,
          launchStabilityMs: 1,
          launchRetryDelaysMs: [],
        },
      },
      runtime,
    );
    expect(pid).toBe(84);
  });

  test("waits for graceful AppKit termination and the LaunchServices settle window", async () => {
    let now = 0;
    const signals: MacApplicationSignal[] = [];
    const runtime: MacApplicationRuntime = {
      now: () => now,
      sleep: async (milliseconds) => {
        now += milliseconds;
      },
      requestTermination: async () => [application],
      isSameProcess: async () => now < 2,
      sendSignal: async (_, signal) => {
        signals.push(signal);
      },
      runningPIDs: async () => unneeded(),
      open: async () => unneeded(),
      log: () => {},
      warn: () => {},
    };

    const wasRunning = await stopMacApplication(
      {
        bundleIdentifier: "com.joeblau.talktext",
        displayName: "TalkText",
        timings: {
          pollIntervalMs: 1,
          gracefulQuitTimeoutMs: 5,
          postQuitSettleMs: 3,
        },
      },
      runtime,
    );

    expect(wasRunning).toBe(true);
    expect(signals).toEqual([]);
    expect(now).toBe(5);
  });

  test("uses bounded SIGTERM escalation when graceful termination hangs", async () => {
    let now = 0;
    let running = true;
    const signals: MacApplicationSignal[] = [];
    const runtime: MacApplicationRuntime = {
      now: () => now,
      sleep: async (milliseconds) => {
        now += milliseconds;
      },
      requestTermination: async () => [application],
      isSameProcess: async () => running,
      sendSignal: async (_, signal) => {
        signals.push(signal);
        if (signal === "SIGTERM") {
          running = false;
        }
      },
      runningPIDs: async () => unneeded(),
      open: async () => unneeded(),
      log: () => {},
      warn: () => {},
    };

    await stopMacApplication(
      {
        bundleIdentifier: "com.joeblau.talktext",
        displayName: "TalkText",
        timings: {
          pollIntervalMs: 1,
          gracefulQuitTimeoutMs: 2,
          terminateTimeoutMs: 2,
          postQuitSettleMs: 1,
        },
      },
      runtime,
    );

    expect(signals).toEqual(["SIGTERM"]);
  });

  test("surfaces the final open diagnostic after bounded retries", async () => {
    let now = 0;
    let openCount = 0;
    const runtime: MacApplicationRuntime = {
      now: () => now,
      sleep: async (milliseconds) => {
        now += milliseconds;
      },
      requestTermination: async () => unneeded(),
      isSameProcess: async () => unneeded(),
      sendSignal: async () => unneeded(),
      runningPIDs: async () => [],
      open: async () => {
        openCount += 1;
        return { exitCode: 1, stdout: "", stderr: "permanent fixture error" };
      },
      log: () => {},
      warn: () => {},
    };

    await expect(
      launchMacApplication(
        {
          appPath: "/fixture/TalkText.app",
          executablePath: application.executablePath,
          executableName: "TalkText",
          displayName: "TalkText",
          timings: {
            pollIntervalMs: 1,
            failedOpenObservationMs: 1,
            launchStabilityMs: 0,
            launchRetryDelaysMs: [1, 1],
          },
        },
        runtime,
      ),
    ).rejects.toThrow("permanent fixture error");
    expect(openCount).toBe(3);
  });
});
