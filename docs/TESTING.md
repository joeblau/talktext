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
- permission/start/stop/recorder callback races, maximum duration, explicit
  state transitions, cancellation, and failure presentation;
- unique session recordings plus cleanup after success, failure, cancellation,
  startup stale-file pruning, and application termination;
- captured-target identity, PID reuse/relaunch, closed windows, target switches,
  activation exhaustion, event failure, and never posting to an unverified app;
- serialized clipboard transactions, checked writes, cancellation handoff,
  restoration, and manual-copy fallback policy without real keystrokes; and
- a static privacy regression check that rejects raw transcript, subprocess
  body, or clipboard-content logging.

Useful focused commands include:

```sh
swift test --package-path TalkText --filter ProcessRunnerTests
swift test --package-path TalkText --filter TranscriptionEngineStateTests
swift test --package-path TalkText --filter TextDeliveryTests
swift test --package-path TalkText --filter PrivacyLoggingTests
```

Before merging, also run the same format and lint gates as CI:

```sh
swiftlint lint --strict --config .swiftlint.yml
swiftformat --lint --config .swiftformat TalkText/Sources TalkText/Tests
```
