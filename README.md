# TalkText

TalkText is a macOS menu bar app for recording speech, transcribing it live at the cursor with Parakeet, and inserting the final transcription into the focused text field.

While recording, TalkText replaces Parakeet's latest draft directly at the
captured cursor and shows an active microphone in the menu bar. Fields that
answer Accessibility are edited in place. Fields that do not, such as Sublime
Text's editor or GPU-rendered terminals, receive drafts as keystrokes: only the
changed tail is deleted and retyped, and only while that app stays frontmost.
Each draft is a full Parakeet pass over a snapshot of the recording so far, so
the first words appear within about half a second and drafts read like the
final text. When recording stops, TalkText cancels the draft loop and replaces the draft
with one final transcription of the complete recording. This final pass uses
fresh decoder state and the same loaded weights. Final text is trimmed without
rewriting identifiers, symbols, or instructions; an LLM cleanup stage is not
part of this workflow.

Hold the right Option key to record and release it to stop, or double-tap it to
lock recording on until the next right-Option press stops it. A single tap does
nothing, so right Option stays usable as an ordinary modifier. TalkText opens
and verifies the microphone silently, discards that warm-up audio, then plays a
short two-note ready chime; speech after the chime is what enters the recording. A distinct
stop cue plays once the microphone closes, including at the recording time
limit, while final transcription continues.

TalkText records from the input chosen under **Input** in the menu bar. The
default follows System Settings, which is rarely what you want if you speak into
an audio interface while the Mac's default input is still the built-in
microphone — pick the interface once and TalkText remembers it, falling back to
the system default whenever that device is unplugged. A recording that never
rises above silence is reported by name instead of submitted to the recognizer.

TalkText does not call a recording ready until microphone buffers have actually
reached its WAV file. If macOS changes an input route during startup or capture
— common when Bluetooth headphones switch profiles — TalkText resolves a fresh
CoreAudio device ID and retries within a fixed bound. An input-only AUHAL keeps
capture independent of playback, and a watchdog recovers stalled input even when
macOS does not send a route notification. Device setup, chime playback, resampling,
and disk writes run off the UI thread. The resampler flushes its trailing audio
on stop and format changes so key-up does not clip the final syllable.

## Requirements

- macOS 14+ on Apple Silicon; Parakeet requires the native arm64 app
- Parakeet TDT 0.6B v2 Core ML assets (about 464 MB; included in packaged apps)
- Python 3.9+ for model setup and bundle verification
- Accessibility access for auto-insert and synthetic paste fallback
- Microphone access

## Local Development

To build the self-contained Universal 2 app and deploy it to
`/Applications/TalkText.app`, run from the repository root or the `TalkText/`
Swift package directory:

```sh
bun talktext
```

This command bundles and verifies the pinned model, signs with the first Apple
Development identity in the local keychain when one is available, and stages
the new bundle before replacing the installed app. If TalkText is running, the
command quits it before deployment and restarts the installed build afterward
through the same verified macOS launch lifecycle.

The launcher identifies the running app by bundle identifier, waits for normal
AppKit cleanup and LaunchServices deregistration, and retries transient macOS
handoff failures such as error `-609`. It only reports success after the exact
new executable has remained running.

Without an Apple Development identity it falls back to ad-hoc signing, which
can require renewed Accessibility and microphone grants after deployment.

From a clean checkout, run:

```sh
./setup.sh
```

Setup downloads and verifies every file of the pinned English Parakeet v2
model, then builds the release executable. FluidAudio 0.17.4 is linked into
TalkText through Swift Package Manager; no separate transcription executable
or Homebrew STT formula is required. Setup prints the built executable path.
Use `bun talktext` to build and deploy the app, or `./bundle.sh` to build a local
app bundle with macOS permissions.
The built executable is located at:

```sh
"$(pwd)/TalkText/.build/release/TalkText"
```

The development executable infers the repository root from its SwiftPM
`.build` path, so it discovers models installed under `models/` without a
machine-specific source path. To build the signed local Universal 2 app bundle
instead, run:

```sh
./bundle.sh
open -a "$PWD/TalkText.app"
```

### Debugging in Xcode

TalkText needs a real app bundle to exercise: microphone access, accessibility,
and the menu-bar-only presentation all depend on it, so `swift run` cannot run
the app. To debug it with breakpoints, generate a development Xcode project:

```sh
brew install xcodegen   # once
./scripts/generate-xcodeproj.sh
open TalkText.xcodeproj
```

The project is generated from [project.yml](project.yml) and is not tracked;
regenerate it after adding or removing sources. It reads the same canonical
`TalkText/Info.plist` and entitlements the release path uses, and a build phase
injects `CFBundleVersion` and `CFBundleShortVersionString` from `VERSION`, so an
Xcode build reports the same version as a released one. Its scheme sets
`TALKTEXT_DEVELOPMENT_ROOT` to `$(SRCROOT)`, because a build running from
DerivedData cannot infer the checkout the way the SwiftPM executable does.

A bare `xcodegen generate` also works. Prefer the script: it additionally fails
when the names in `project.yml` drift from the canonical `Info.plist`, and it
resolves local signing, neither of which a plain `xcodegen` run can do.

Development builds are signed with your own Apple Development certificate, which
the script finds in your keychain and writes to an untracked `Local.xcconfig`.
When the keychain holds several teams, it prefers team `K78G42H4U2`; set
`TALKTEXT_DEVELOPMENT_TEAM` to choose a different one. This matters for more than trust prompts: an ad-hoc signature's designated
requirement pins the exact code hash, so every rebuild invalidates the
Accessibility and microphone grants and macOS re-prompts on the next paste, while
the stale entry still shows as enabled in System Settings. A certificate identity
keeps that requirement stable, so the grants survive rebuilds. Without a
certificate the project still builds ad-hoc, with that caveat.

After switching signing identities, clear the stale grant once:

```sh
tccutil reset Accessibility com.joeblau.talktext
```

Xcode builds are ad-hoc signed and for development only. Release artifacts still
come from `./bundle.sh`, which is what CI verifies.

See [docs/RELEASING.md](docs/RELEASING.md) for the architecture, signing,
notarization, and required-check policy.

## Parakeet transcription workflow

The app loads Parakeet TDT 0.6B v2 through [FluidAudio](https://github.com/FluidInference/FluidAudio).
It uses Core ML's CPU and Neural Engine on Apple Silicon. The Universal 2 app
shows an unsupported-hardware message on Intel or under Rosetta before loading
models. Weights remain resident between recordings. The first load may take
longer while Core ML compiles for the device.

Live preview re-transcribes a snapshot of the open recording every quarter
second plus inference time. Parakeet decodes 3 seconds of audio in under 0.1
seconds, 30 seconds in about 0.2 seconds, and the 5-minute maximum in about 0.9
seconds on Apple Silicon, so drafts stay current for the whole recording. When
recording stops, the microphone closes promptly, preview work is cancelled, and
the complete recording receives one final audio pass before delivery without
waiting for preview cleanup.

Inference is offline. TalkText uses `AsrModels.loadLocal`, disables SDK network
fetches, and suppresses SDK transcript logging. Setup is the only model-download
step. Optional vocabulary boosting and LLM text cleanup can be added separately.

## Dependency discovery and preflight

TalkText resolves and loads local models before requesting microphone permission
or allocating recording files. Missing, incomplete, unreadable, or incorrectly
sized assets become visible setup errors. Core ML load failures remain distinct
from successful no-speech results. Startup logs include the SDK version and
resolution source; paths remain private and dictated text is never logged.

Model directories are searched in this order:

1. `TALKTEXT_MODEL_PATH`, an explicit directory override (relative paths resolve
   against the working directory). An invalid override fails without fallback.
2. Bundled `Contents/Resources/models/parakeet-tdt-0.6b-v2-coreml`.
3. `models/parakeet-tdt-0.6b-v2-coreml` under `TALKTEXT_DEVELOPMENT_ROOT`, the
   checkout inferred from a SwiftPM executable, the working directory, and its
   parent.
4. `~/Library/Application Support/TalkText/models/parakeet-tdt-0.6b-v2-coreml`.

An incomplete preferred directory fails without silently selecting other weights.
`TALKTEXT_MODEL_PATH` now names a directory, rather than a GGML file. Remove old
Whisper-specific environment overrides when migrating an existing checkout.

## Pinned model supply chain

[`parakeet-model.json`](TalkText/Sources/TalkText/Resources/parakeet-model.json)
pins the model repository, immutable revision, and exact size and SHA-256 for
all 21 required Core ML files. [`dependencies.env`](dependencies.env) mirrors the
reviewed model identity and SDK version; tests prevent those values from drifting.
[`Package.resolved`](TalkText/Package.resolved) pins the FluidAudio source revision.

The model installer verifies cached assets before avoiding the network. Downloads
use the immutable revision, bounded retries, and a temporary directory. Every file
must pass size and digest checks before installation. A corrupt existing cache is
retained under an `.invalid.<uuid>` directory after a verified replacement is
ready; failed downloads leave the prior cache untouched.

Setup, bundle assembly, and bundle verification use the same verifier:

```sh
./scripts/dependency-tool.sh verify-model ./models/parakeet-tdt-0.6b-v2-coreml
```

Production setup and release reject alternate model manifests. Developer ID
bundling also rejects manifest overrides. CI uses a small deterministic fixture
to verify packaging, plus real model inference on Apple Silicon and the
unsupported-hardware guard on Intel.

To update the dependency, review the SDK pin, the immutable model revision, every
file size and digest, the resolver contract, and native inference checks together.
Run the Swift, model-installer, lint, and bundle gates before publishing.

The original [NVIDIA Parakeet TDT v2 model](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)
is licensed under CC BY 4.0; the Core ML conversion is provided by FluidInference.
FluidAudio is licensed under Apache 2.0.

## Homebrew Tap

Once the tap is published, install with:

```sh
brew tap joeblau/tap
brew install --cask talktext
```
