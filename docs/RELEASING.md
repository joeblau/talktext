# Release and architecture policy

## Supported Macs

TalkText supports macOS 14 or newer on both Apple Silicon (`arm64`) and Intel
(`x86_64`). Every distributable app is Universal 2. The bundled GGML model is
architecture-neutral, while the separately installed `whisper-cli` backend
must be compatible with the user's Mac. `bundle.sh`, CI, and `release.sh` all
reject an app whose executable does not contain exactly those two slices.

CI compiles and launches the app on the pinned `macos-15-intel` image. A
separate native backend matrix uses `macos-15-intel` for `x86_64` and
`macos-15` for `arm64`. Both app slices are separately compiled with the macOS
14 deployment target and warnings treated as errors before `lipo` creates the
final binary.

## Canonical release metadata

- `TalkText/Info.plist` is the only source for the bundle identifier,
  executable name, minimum system version, permission text, and other bundle
  metadata. It intentionally contains no version keys.
- `VERSION` is the only version source. It must be one line containing a
  three-component numeric semantic version such as `1.2.3`.
- Public releases use that same value for both
  `CFBundleShortVersionString` and `CFBundleVersion`. This is the explicit build
  number policy: a new public build requires a version bump; mutable rebuilds
  under an existing version are not published.
- The source tag must be exactly `v<the VERSION value>`, point at `HEAD`, and
  the checkout must be clean. The archive is named
  `TalkText-<VERSION>.zip`.
- `TalkText/TalkText.entitlements` is the reviewed, canonical entitlement set.
  The final signing command consumes it, and bundle verification compares the
  entitlements embedded in the code signature with that file.

## Signing modes

`./bundle.sh` defaults to deterministic ad-hoc signing. This seals the final
bundle and lets CI run strict signature, resource, metadata, entitlement, and
architecture checks without access to release credentials. It is not a
distributable or Gatekeeper-trusted signature.

`./release.sh` is a separate fail-closed path. It forces Developer ID signing
with hardened runtime after all executable, plist, and resource changes. It
then submits a transport zip to Apple's notary service, requires an `Accepted`
result, staples the ticket, runs strict `codesign`, `stapler`, and `spctl`
checks, creates the final zip, extracts it, and repeats all checks against the
extracted app.

For a local release, export:

```sh
export TALKTEXT_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
export APPLE_TEAM_ID='TEAMID'
export APPLE_ID='release@example.com'
export APPLE_APP_SPECIFIC_PASSWORD='xxxx-xxxx-xxxx-xxxx'
export TALKTEXT_RELEASE_TAG="v$(./scripts/read-version.sh)"
./scripts/dependency-tool.sh install-model
./release.sh
```

Instead of `APPLE_ID` and `APPLE_APP_SPECIFIC_PASSWORD`, maintainers may set
`NOTARYTOOL_PROFILE` to a profile already created by `notarytool
store-credentials`. Set `NOTARYTOOL_KEYCHAIN` as well when that profile is in a
non-default keychain. `APPLE_TEAM_ID` remains required so the extracted
artifact's TeamIdentifier can be checked.

## GitHub Actions credentials and publication

The `Release` workflow requires all six repository secrets below:

- `MACOS_CERTIFICATE_BASE64`: base64-encoded Developer ID Application PKCS#12
- `MACOS_CERTIFICATE_PASSWORD`: password for that PKCS#12
- `MACOS_SIGNING_IDENTITY`: full Developer ID Application identity name
- `APPLE_ID`: Apple account used by `notarytool`
- `APPLE_TEAM_ID`: Developer Program team identifier
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password for the Apple account

The workflow imports the certificate into an ephemeral keychain. A missing or
invalid secret, identity, timestamp, notary result, staple, signature,
architecture, plist value, embedded entitlement, Gatekeeper assessment, or
archive check stops the job. It creates a draft GitHub release, downloads and
verifies that exact draft asset a second time, and only then publishes the
release. A failure in the download check leaves a draft rather than a public
release.

## Required branch check

Repository administrators must protect `main` and require the exact status
check context `CI / Required`. Pull requests and pushes to `main` run that
check. Tag releases call the same reusable workflow first, and publishing
cannot start unless it succeeds.

The check pins macOS to `macos-15-intel` and `macos-15`, Xcode to 16.4, CMake
to an installed executable that reports exactly 4.1.2, third-party lint tool versions and
archive digests, and every GitHub Action to a full commit SHA. SwiftPM, model,
backend, and tool caches use explicit, versioned keys. The gate covers:

- debug and release Universal 2 compilation with warnings as errors
- all Swift and dependency fixture tests
- native execution of the byte-for-byte production `whisper-cli` invocation
  for every pinned backend version on both Intel and Apple Silicon
- shell syntax and source plist validation
- SwiftLint and SwiftFormat using committed configuration
- bundle executable, resources, model digest, canonical metadata, exact
  architecture slices, hardened runtime, resource seal, strict signature, and
  embedded entitlement checks
- zip extraction followed by the same bundle checks and an Intel launch smoke
  test

Branch protection and repository secrets are GitHub-hosted settings and cannot
be established by committed workflow files. Configure them before treating the
release workflow as operational.
