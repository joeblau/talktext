import { join, resolve } from "node:path";

const repositoryRoot = resolve(import.meta.dir, "..");
const packageRoot = join(repositoryRoot, "TalkText");
const derivedDataPath = join(packageRoot, ".build", "xcode");
const projectPath = join(repositoryRoot, "TalkText.xcodeproj");
const appPath = join(
  derivedDataPath,
  "Build",
  "Products",
  "Debug",
  "TalkText.app",
);
const executablePath = join(appPath, "Contents", "MacOS", "TalkText");

async function run(command: string[]) {
  const process = Bun.spawn(command, {
    cwd: repositoryRoot,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await process.exited;
  if (exitCode !== 0) {
    throw new Error(`Command failed (${exitCode}): ${command.join(" ")}`);
  }
}

async function isTalkTextRunning() {
  const process = Bun.spawn(["/usr/bin/pgrep", "-x", "TalkText"], {
    stdout: "ignore",
    stderr: "ignore",
  });
  return (await process.exited) === 0;
}

async function stopRunningApp() {
  if (!(await isTalkTextRunning())) {
    return;
  }

  console.log("==> Stopping the running TalkText app...");
  const quit = Bun.spawn(
    [
      "/usr/bin/osascript",
      "-e",
      'tell application id "com.joeblau.talktext" to quit',
    ],
    { stdout: "ignore", stderr: "ignore" },
  );
  await quit.exited;

  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (!(await isTalkTextRunning())) {
      return;
    }
    await Bun.sleep(100);
  }

  throw new Error(
    "TalkText did not quit. Stop it from the menu bar, then run `bun macos` again.",
  );
}

if (process.platform !== "darwin") {
  throw new Error("`bun macos` can only build TalkText on macOS.");
}

console.log("==> Preparing the TalkText development project...");
await run([join(repositoryRoot, "scripts", "generate-xcodeproj.sh")]);

console.log("==> Building TalkText for macOS...");
await run([
  "/usr/bin/xcodebuild",
  "-project",
  projectPath,
  "-scheme",
  "TalkText",
  "-destination",
  `platform=macOS,arch=${process.arch === "arm64" ? "arm64" : "x86_64"}`,
  "-configuration",
  "Debug",
  "-derivedDataPath",
  derivedDataPath,
  "-quiet",
  "build",
]);

if (!(await Bun.file(executablePath).exists())) {
  throw new Error(`The build succeeded but TalkText is missing at ${appPath}.`);
}

await stopRunningApp();

console.log(`==> Launching ${appPath}`);
await run([
  "/usr/bin/open",
  "--env",
  `TALKTEXT_DEVELOPMENT_ROOT=${repositoryRoot}`,
  appPath,
]);
