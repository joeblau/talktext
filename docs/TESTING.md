# Testing TalkText

Run the complete engine suite from the repository root:

```sh
swift test --package-path TalkText -Xswiftc -warnings-as-errors
```

The safety-critical coverage expectation is behavioral rather than a single
line-percentage target. A change must keep deterministic tests for:

- concurrent stdout/stderr draining, launch errors, exit status, signals,
  timeout, and task cancellation in the process runner;
- dependency preflight before recording, output cleanup, and the distinction
  between successful no-speech output and every transcription failure;
- permission/start/stop/recorder callback races, verified input readiness,
  cancellation while audio is still opening, maximum duration, explicit state
  transitions, and failure presentation;
- resampling across input-rate changes, discarded warm-up audio, complete
  trailing samples on stop, input metering, and final inference proceeding while
  cancelled preview work cleans up;
- unique session recordings plus cleanup after success, failure, cancellation,
  startup stale-file pruning, and application termination;
- captured-target identity, PID reuse/relaunch, closed windows, target switches,
  activation exhaustion, event failure, and never posting to an unverified app;
- serialized clipboard transactions, checked writes, cancellation handoff,
  restoration, and manual-copy fallback policy without real keystrokes; and
- a static privacy regression check that rejects raw transcript, subprocess
  body, or clipboard-content logging.

The ordinary Swift suite uses injected recognizers and requires no model download.
The real-model test checks draft text from snapshots of an open recording within
the first three seconds of input and final inference during preview cancellation.
It uses fixture audio, not microphone access. AirPods profile negotiation and
audible cue playback still need a hardware check: select the AirPods under Input,
hold Right Option until the ready chime, speak, check the panel's level meter and
draft, then release. Repeat immediately and check that input recovers after an
AirPods reconnect.

Run the model installer, cache, and release-source fixtures with:

```sh
bash tests/dependency-tool-fixtures.sh
```

After installing the pinned weights, exercise real final transcription and live
preview without recording the microphone or posting keystrokes:

```sh
./scripts/dependency-tool.sh install-model
TALKTEXT_PARAKEET_SMOKE_TEST=1 swift test --package-path TalkText --filter ParakeetIntegrationTests
```

The integration fixture `tests/fixtures/jfk.wav` comes from
`ggml-org/whisper.cpp` at commit `9386f239401074690479731c1e41683fbbeac557`
(`samples/jfk.wav`, SHA-256 `59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`).
It contains public speech, not a user's recording. Native CI runs real inference on
Apple Silicon and tests the unsupported-hardware preflight on Intel. Core ML
prediction with these assets crashed under Rosetta during local verification;
TalkText rejects x86_64 inference before loading any model.

Useful focused commands include:

```sh
swift test --package-path TalkText --filter ParakeetTranscriberTests
swift test --package-path TalkText --filter TranscriptionEngineStateTests
swift test --package-path TalkText --filter TextDeliveryTests
swift test --package-path TalkText --filter PrivacyLoggingTests
```

Before merging, also run the same format and lint gates as CI:

```sh
swiftlint lint --strict --config .swiftlint.yml
swiftformat --lint --config .swiftformat TalkText/Sources TalkText/Tests
```
