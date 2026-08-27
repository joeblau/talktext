import { join, resolve } from "node:path";
import {
  launchMacApplication,
  stopMacApplication,
} from "./macos-app-lifecycle";

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

await stopMacApplication({
  bundleIdentifier: "com.joeblau.talktext",
  displayName: "TalkText",
});

console.log(`==> Launching ${appPath}`);
await launchMacApplication({
  appPath,
  executablePath,
  executableName: "TalkText",
  displayName: "TalkText",
  environment: {
    TALKTEXT_DEVELOPMENT_ROOT: repositoryRoot,
  },
});
