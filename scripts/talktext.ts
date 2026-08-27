import { access, mkdtemp, mkdir, rename, rm } from "node:fs/promises";
import { join, resolve } from "node:path";
import {
  launchMacApplication,
  stopMacApplication,
} from "./macos-app-lifecycle";

const repositoryRoot = resolve(import.meta.dir, "..");
const sourceAppPath = join(repositoryRoot, "TalkText.app");
const applicationsPath = "/Applications";
const installedAppPath = join(applicationsPath, "TalkText.app");
const installedExecutablePath = join(
  installedAppPath,
  "Contents",
  "MacOS",
  "TalkText",
);

type SigningConfiguration = {
  mode: "adhoc" | "apple-development";
  environment: Record<string, string>;
  summary: string;
};

async function run(
  command: string[],
  environment: Record<string, string> = {},
) {
  const child = Bun.spawn(command, {
    cwd: repositoryRoot,
    env: { ...process.env, ...environment },
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await child.exited;
  if (exitCode !== 0) {
    throw new Error(`Command failed (${exitCode}): ${command.join(" ")}`);
  }
}

async function capture(command: string[], input?: Blob) {
  const child = Bun.spawn(command, {
    cwd: repositoryRoot,
    stdin: input ?? "ignore",
    stdout: "pipe",
    stderr: "ignore",
  });
  const output = await new Response(child.stdout).text();
  return { exitCode: await child.exited, output };
}

async function localSigningConfiguration(): Promise<SigningConfiguration> {
  const identities = await capture([
    "/usr/bin/security",
    "find-identity",
    "-v",
    "-p",
    "codesigning",
  ]);
  const match = identities.output.match(/"(Apple Development: [^"]+)"/);

  if (identities.exitCode === 0 && match) {
    const identity = match[1];
    const certificate = await capture([
      "/usr/bin/security",
      "find-certificate",
      "-c",
      identity,
      "-p",
    ]);
    const subject = await capture(
      ["/usr/bin/openssl", "x509", "-noout", "-subject"],
      new Blob([certificate.output]),
    );
    const teamID = subject.output.match(
      /(?:^|[,/])\s*OU\s*=\s*([A-Z0-9]+)/,
    )?.[1];

    if (certificate.exitCode === 0 && subject.exitCode === 0 && teamID) {
      return {
        mode: "apple-development",
        environment: {
          TALKTEXT_SIGNING_MODE: "apple-development",
          TALKTEXT_SIGNING_IDENTITY: identity,
          TALKTEXT_EXPECTED_TEAM_ID: teamID,
        },
        summary: `${identity} (team ${teamID})`,
      };
    }
  }

  console.warn(
    "warning: no Apple Development identity found; falling back to ad-hoc signing.\n" +
      "         macOS permission grants may need to be renewed after each deployment.",
  );
  return {
    mode: "adhoc",
    environment: { TALKTEXT_SIGNING_MODE: "adhoc" },
    summary: "ad-hoc",
  };
}

async function pathExists(path: string) {
  try {
    await access(path);
    return true;
  } catch (error) {
    if ((error as { code?: string }).code === "ENOENT") {
      return false;
    }
    throw error;
  }
}

async function deploy(signing: SigningConfiguration) {
  await mkdir(applicationsPath, { recursive: true });

  // /Applications is group-writable by admin. A standard account cannot stage
  // there, and the failure is worth naming rather than surfacing as EACCES.
  let transactionPath: string;
  try {
    transactionPath = await mkdtemp(join(applicationsPath, ".talktext-install-"));
  } catch (error) {
    const code = (error as { code?: string }).code;
    if (code === "EACCES" || code === "EPERM") {
      throw new Error(
        `${applicationsPath} is not writable by this account. ` +
          "Deploy from an administrator account, or install TalkText.app there by hand.",
      );
    }
    throw error;
  }
  const stagedAppPath = join(transactionPath, "TalkText.app");
  const previousAppPath = join(transactionPath, "previous-TalkText.app");
  let previousAppWasMoved = false;

  try {
    console.log(`==> Staging ${installedAppPath}...`);
    await run(["/usr/bin/ditto", sourceAppPath, stagedAppPath]);
    await run(
      [join(repositoryRoot, "scripts", "verify-bundle.sh"), stagedAppPath],
      {
        ...signing.environment,
        TALKTEXT_EXPECTED_SIGNATURE: signing.mode,
      },
    );

    if (await pathExists(installedAppPath)) {
      await rename(installedAppPath, previousAppPath);
      previousAppWasMoved = true;
    }

    try {
      await rename(stagedAppPath, installedAppPath);
    } catch (error) {
      if (previousAppWasMoved) {
        await rename(previousAppPath, installedAppPath);
        previousAppWasMoved = false;
      }
      throw error;
    }

    if (previousAppWasMoved) {
      await rm(previousAppPath, { recursive: true, force: true });
      previousAppWasMoved = false;
    }
  } finally {
    if (previousAppWasMoved && !(await pathExists(installedAppPath))) {
      await rename(previousAppPath, installedAppPath);
      previousAppWasMoved = false;
    }
    await rm(transactionPath, { recursive: true, force: true });
  }
}

if (process.platform !== "darwin") {
  throw new Error("`bun talktext` can only build and deploy TalkText on macOS.");
}

const signing = await localSigningConfiguration();
console.log("==> Building the self-contained Universal 2 TalkText app...");
console.log(`    Signing: ${signing.summary}`);
await run([join(repositoryRoot, "bundle.sh")], signing.environment);

const wasRunning = await stopMacApplication({
  bundleIdentifier: "com.joeblau.talktext",
  displayName: "TalkText",
});
await deploy(signing);

if (!(await Bun.file(installedExecutablePath).exists())) {
  throw new Error(
    `Deployment completed but the TalkText executable is missing at ${installedExecutablePath}.`,
  );
}

if (wasRunning) {
  console.log("==> Restarting the installed TalkText app...");
  await launchMacApplication({
    appPath: installedAppPath,
    executablePath: installedExecutablePath,
    executableName: "TalkText",
    displayName: "TalkText",
  });
}

console.log(`==> TalkText deployed: ${installedAppPath}`);
