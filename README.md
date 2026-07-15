# TalkText

TalkText is a macOS menu bar app for recording speech, transcribing it with `whisper-cli`, and inserting the transcription into the focused text field.

## Requirements

- macOS 14+ on Apple Silicon or Intel (the app is Universal 2)
- A supported `whisper-cli`: `whisper-cpp` 1.8.4 or 1.9.1
- Accessibility access for auto-insert and synthetic paste fallback
- Microphone access

## Local Development

From a clean checkout, run:

```sh
./setup.sh
```

Setup resolves or installs a supported backend, downloads the pinned
`ggml-distil-large-v3.bin` model with retries and verification, and builds the
release executable. It prints an absolute, shell-escaped command that works
from the caller's current directory. The equivalent command from the
repository root is:

```sh
"$(pwd)/TalkText/.build/release/TalkText"
```

The development executable infers the repository root from its SwiftPM
`.build` path, so it discovers the model installed at `models/` without a
machine-specific source path. To build the signed local Universal 2 app bundle
instead, run:

```sh
./bundle.sh
open TalkText.app
```

See [docs/RELEASING.md](docs/RELEASING.md) for the architecture, signing,
notarization, and required-check policy.

## Dependency discovery and preflight

TalkText performs dependency preflight before requesting microphone permission
or allocating a recording. It requires the model to be a readable regular GGML
file of the pinned size, and `whisper-cli` to be readable, executable, an exact
supported version, and to advertise every production option. Failures are
shown as actionable setup errors before recording starts. Startup diagnostics
record the resolution source and backend version; resolved paths are logged as
private metadata and no dictated content is included.

Backend resolution uses the same policy in setup and the app, in this order:

1. `TALKTEXT_WHISPER_CLI` explicit override
2. `Contents/Resources/bin/whisper-cli` in a packaged app
3. `PATH`
4. `HOMEBREW_PREFIX`, `/opt/homebrew`, then `/usr/local`
5. `.dependencies/bin` or `bin` under `TALKTEXT_DEVELOPMENT_ROOT` or an inferred checkout
6. `~/.local/bin`

Model resolution uses `TALKTEXT_MODEL_PATH`, bundled `Resources/models`, the
inferred checkout's `models/`, per-user application data, then Homebrew model
locations. An explicit but invalid override fails closed instead of silently
selecting another file.

Homebrew 1.8.4 does not implement `--version`, so the resolver can derive its
version from the resolved Cellar path. A custom or bundled executable must
report its version, have a neighboring `<executable>.version` file, or be paired
with a reviewed `TALKTEXT_WHISPER_CLI_VERSION` override. An unreported or
unsupported version is rejected even when its flags happen to look compatible.

## Pinned model supply chain

[`dependencies.env`](dependencies.env) is the only reviewed manifest for the
model repository, immutable upstream revision, URL, exact byte size, GGML
magic, and SHA-256. `scripts/dependency-tool.sh install-model` downloads into a
temporary file in the destination directory using HTTP failure handling and
retries. It validates format, size, and digest before an atomic rename. A valid
cache avoids the network; an invalid cache is reported, replaced only after a
verified download succeeds, and retained under an `.invalid.<timestamp>`
quarantine name for diagnosis.

Setup, bundling, and release all use the same verifier. To audit a local cache:

```sh
./scripts/dependency-tool.sh verify-model ./models/ggml-distil-large-v3.bin
```

Updating the model is an explicit dependency review:

1. Select an immutable upstream revision—never a moving branch such as `main`.
2. Independently download the object and record its repository, revision, URL,
   byte size, GGML magic, and locally computed SHA-256 in `dependencies.env`.
3. Run `tests/dependency-tool-fixtures.sh`, `swift test --package-path TalkText`,
   and a verified bundle build.
4. Review the manifest diff and record the model revision/digest in release
   notes before publishing.

## Supported whisper-cli contract

TalkText supports these exact backend builds, not an untested semantic-version
range:

| Version | Immutable upstream revision |
| --- | --- |
| 1.8.4 | `9386f239401074690479731c1e41683fbbeac557` |
| 1.9.1 | `f049fff95a089aa9969deb009cdd4892b3e74916` |

The repository URL, exact version list, revisions, and required flags are
canonical in `dependencies.env`. Production invokes:

```text
whisper-cli --model <model> --file <controlled.wav> --no-timestamps --threads 4
```

CI builds each pinned revision natively on Intel and Apple Silicon and runs
that exact invocation against a deterministic 16 kHz mono PCM fixture through
`tests/backend-contract-fixture.sh`. Unit tests also lock the production
argument array, resolver precedence, version policy, and missing/incompatible
failure behavior.

A backend upgrade requires adding the exact version and full upstream commit
to the manifest, building it for both architectures, running the real backend
fixture plus the full Swift/shell suite, and reviewing compatibility evidence.
Only then may the compiled supported-version list change. Release notes must
record the supported backend versions/revisions and any contract change for
that TalkText version.

## Homebrew Tap

Once the tap is published, install with:

```sh
brew tap joeblau/tap
brew install --cask talktext
```
