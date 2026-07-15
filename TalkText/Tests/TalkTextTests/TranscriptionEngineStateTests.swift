import AppKit
import Darwin
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class TranscriptionEngineStateTests: XCTestCase {
    func testDependenciesArePreflightedBeforePermissionOrRecorderSideEffects() async {
        let preflight = EnginePreflightFake(result: nil)
        let permission = EnginePermissionFake()
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            preflight: preflight,
            permission: permission,
            factory: factory,
            store: store
        )

        engine.toggleRecording()

        XCTAssertEqual(engine.state, .starting)
        XCTAssertEqual(permission.statusCallCount, 0)
        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertEqual(store.allocatedURLs.count, 0)

        preflight.resolve(EngineFixtures.readyPreflightResult)
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(permission.statusCallCount, 1)
        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(store.allocatedURLs.count, 1)
    }

    func testPreflightFailureIsActionableAndFailsBeforeMicrophonePermission() async {
        let failure = TalkTextDependencyPreflightFailure.missingBinary(
            searchedPaths: ["/private/fixture/whisper-cli"]
        )
        let preflight = EnginePreflightFake(result: .failure(failure))
        let permission = EnginePermissionFake()
        let factory = EngineRecorderFactoryFake()
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            preflight: preflight,
            permission: permission,
            factory: factory,
            store: store
        )

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertTrue(engine.statusText.contains("setup.sh"))
        XCTAssertEqual(permission.statusCallCount, 0)
        XCTAssertEqual(factory.creationCount, 0)
        XCTAssertEqual(store.allocatedURLs.count, 0)
    }

    func testLaunchPreparationIsCachedButEveryRecordingRevalidatesDependencies() async {
        let preflight = EnginePreflightFake()
        let engine = makeEngine(preflight: preflight)

        engine.prepareDependencies()
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(preflight.invocationCount, 1)

        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(preflight.invocationCount, 2)
    }

    func testRepeatedTogglesWhilePermissionPendingCannotStartMultipleRecorders() async {
        let permission = EnginePermissionFake(status: .notDetermined)
        let factory = EngineRecorderFactoryFake()
        let engine = makeEngine(permission: permission, factory: factory)

        engine.toggleRecording()
        await waitUntil {
            engine.state == .requestingPermission && permission.requestCount == 1
        }
        engine.toggleRecording()
        engine.toggleRecording()

        XCTAssertEqual(permission.requestCount, 1)
        XCTAssertEqual(factory.creationCount, 0)

        permission.resolveAccess(granted: true)
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(factory.creationCount, 1)
    }

    func testPermissionCallbackAfterCancellationCannotStartRecorder() async {
        let permission = EnginePermissionFake(status: .notDetermined)
        let factory = EngineRecorderFactoryFake()
        let engine = makeEngine(permission: permission, factory: factory)

        engine.toggleRecording()
        await waitUntil { engine.state == .requestingPermission }
        engine.cancelCurrentOperation()
        permission.resolveAccess(granted: true)
        await spinMainActor()

        XCTAssertEqual(engine.state, .failed)
        XCTAssertEqual(factory.creationCount, 0)
    }

    func testDeniedRestrictedAndUnknownPermissionFailClosed() async {
        let cases: [(MicrophoneAuthorization, String)] = [
            (.denied, "denied"),
            (.restricted, "restricted"),
            (.unknown, "could not be determined"),
        ]

        for (authorization, expectedText) in cases {
            let factory = EngineRecorderFactoryFake()
            let engine = makeEngine(
                permission: EnginePermissionFake(status: authorization),
                factory: factory
            )
            engine.toggleRecording()
            await waitUntil { engine.state == .failed }

            XCTAssertTrue(engine.statusText.localizedCaseInsensitiveContains(expectedText))
            XCTAssertEqual(factory.creationCount, 0)
        }
    }

    func testRecorderStartFailureCleansSessionFileAndShowsFailure() async {
        let recorder = EngineRecorderFake()
        recorder.startResult = false
        let store = EngineFileStoreFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: store
        )

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertEqual(store.allocatedURLs.count, 1)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        XCTAssertTrue(engine.statusText.contains("could not start"))
    }

    func testRecorderConstructionFailureCleansAllocatedSessionFile() async {
        let factory = EngineRecorderFactoryFake()
        factory.creationError = CocoaError(.fileWriteUnknown)
        let store = EngineFileStoreFake()
        let engine = makeEngine(factory: factory, store: store)

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        XCTAssertTrue(engine.statusText.contains("could not be created"))
    }

    func testSynchronousRecorderCompletionDuringStartCannotReportRecording() async {
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        recorder.onStart = { factory.emit(.unexpectedCompletion) }
        let store = EngineFileStoreFake()
        let engine = makeEngine(factory: factory, store: store)

        engine.toggleRecording()
        await waitUntil { engine.state == .failed }

        XCTAssertEqual(factory.creationCount, 1)
        XCTAssertEqual(store.removedURLs.count, 1)
        XCTAssertTrue(engine.statusText.contains("unexpectedly"))
    }

    func testRecorderFailureCallbacksAreVisibleAndAlwaysCleanAudio() async {
        let events: [RecorderEvent] = [
            .interrupted,
            .deviceUnavailable,
            .encodeError(RecorderErrorDiagnostic(domain: "fixture", code: 7)),
            .unexpectedCompletion,
        ]

        for event in events {
            let store = EngineFileStoreFake()
            let factory = EngineRecorderFactoryFake()
            let engine = makeEngine(factory: factory, store: store)
            engine.toggleRecording()
            await waitUntil { engine.state == .recording }

            factory.emit(event)

            XCTAssertEqual(engine.state, .failed)
            XCTAssertEqual(store.removedURLs.count, 1)
        }
    }

    func testEveryRecorderStopFailureCleansAllocatedSessionFile() async {
        let failures: [RecorderStopOutcome] = [
            .notRecording,
            .encodeError(RecorderErrorDiagnostic(domain: "fixture", code: 17)),
            .unsuccessfulCompletion,
            .finalizationTimedOut,
            .cancelled,
        ]

        for failure in failures {
            let recorder = EngineRecorderFake()
            recorder.immediateStopOutcome = failure
            let store = EngineFileStoreFake()
            let engine = makeEngine(
                factory: EngineRecorderFactoryFake(recorders: [recorder]),
                store: store
            )
            engine.toggleRecording()
            await waitUntil { engine.state == .recording }

            engine.toggleRecording()
            await waitUntil { engine.state == .failed }

            XCTAssertEqual(store.allocatedURLs.count, 1)
            XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        }
    }

    func testRecorderCallbackRaceWhileStoppingCannotAdvanceStaleSuccess() async {
        let recorder = EngineRecorderFake()
        recorder.immediateStopOutcome = nil
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let store = EngineFileStoreFake()
        let transcriber = EngineTranscriberFake(outcome: nil)
        let engine = makeEngine(
            factory: factory,
            store: store,
            transcriber: transcriber
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }

        engine.toggleRecording()
        await waitUntil { recorder.stopCount == 1 && engine.state == .stopping }
        factory.emit(.encodeError(RecorderErrorDiagnostic(domain: "fixture", code: 9)))
        recorder.completeStop(with: .finished)
        await spinMainActor()

        XCTAssertEqual(engine.state, .failed)
        XCTAssertEqual(transcriber.invocationCount, 0)
        XCTAssertEqual(store.removedURLs.count, 1)
    }

    func testMaximumDurationFinalizesThenTranscribesExactlyOnce() async {
        let recorder = EngineRecorderFake()
        let factory = EngineRecorderFactoryFake(recorders: [recorder])
        let store = EngineFileStoreFake()
        let transcriber = EngineTranscriberFake(outcome: nil)
        let engine = makeEngine(
            factory: factory,
            store: store,
            transcriber: transcriber
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }

        factory.emit(.maximumDurationReached)
        await waitUntil { engine.state == .transcribing && transcriber.invocationCount == 1 }

        XCTAssertEqual(recorder.maximumDurations, [TranscriptionEngine.maximumRecordingDuration])
        transcriber.resolve(.noSpeech)
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(store.removedURLs.count, 1)
    }

    func testRapidTogglesCannotStartAnotherSessionWhileDeliveryIsPending() async {
        let store = EngineFileStoreFake()
        let delivery = EngineDeliveryFake(outcome: nil)
        let factory = EngineRecorderFactoryFake(
            recorders: [EngineRecorderFake(), EngineRecorderFake()]
        )
        let engine = makeEngine(
            factory: factory,
            store: store,
            transcriber: EngineTranscriberFake(outcome: .success("secret")),
            delivery: delivery
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }

        engine.toggleRecording()
        await waitUntil { engine.state == .delivering && delivery.deliveredTexts.count == 1 }

        XCTAssertFalse(engine.isInteractive)
        XCTAssertEqual(store.removedURLs.count, 1)
        engine.toggleRecording()
        engine.toggleRecording()
        engine.toggleRecording()
        await spinMainActor()

        XCTAssertEqual(delivery.captureCount, 1, "No second session may start")
        XCTAssertEqual(factory.creationCount, 1, "No second recorder may start")
        XCTAssertEqual(delivery.deliveredTexts, ["secret"], "No second delivery may start")

        delivery.resolve(.inserted)
        await waitUntil { engine.state == .idle }
        XCTAssertEqual(engine.statusText, "Inserted! Press Ctrl+Space to record")

        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        XCTAssertEqual(delivery.captureCount, 2)
        XCTAssertEqual(factory.creationCount, 2)
        XCTAssertEqual(delivery.deliveredTexts, ["secret"])
        engine.cancelCurrentOperation()
    }

    func testEveryTranscriptionTerminalOutcomeCleansRecording() async {
        let diagnostic = ProcessDiagnostic(
            terminationStatus: 3,
            terminationReason: .exit,
            standardError: Data("diagnostic".utf8)
        )
        let outcomes: [(TranscriptionOutcome, TranscriptionEngine.State)] = [
            (.noSpeech, .idle),
            (.missingDependency(.binary), .failed),
            (.invalidAudio(.empty), .failed),
            (.launchFailed(ProcessDiagnostic(launchErrorDomain: NSPOSIXErrorDomain, launchErrorCode: 2)), .failed),
            (.processFailed(diagnostic), .failed),
            (.timedOut(diagnostic), .failed),
            (.cancelled(diagnostic), .failed),
        ]

        for (outcome, expectedState) in outcomes {
            let store = EngineFileStoreFake()
            let engine = makeEngine(
                store: store,
                transcriber: EngineTranscriberFake(outcome: outcome)
            )
            engine.toggleRecording()
            await waitUntil { engine.state == .recording }
            engine.toggleRecording()
            await waitUntil { engine.state == expectedState && !store.removedURLs.isEmpty }

            XCTAssertEqual(store.removedURLs.count, 1)
        }
    }

    func testCancellationAndNormalTerminationCleanActiveAudio() async {
        let recordingStore = EngineFileStoreFake()
        let recorder = EngineRecorderFake()
        let recordingEngine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: recordingStore
        )
        recordingEngine.toggleRecording()
        await waitUntil { recordingEngine.state == .recording }

        recordingEngine.cancelCurrentOperation()

        XCTAssertEqual(recordingEngine.state, .failed)
        XCTAssertEqual(recordingStore.removedURLs.count, 1)
        XCTAssertEqual(recorder.cancelCount, 1)

        let terminationStore = EngineFileStoreFake()
        let terminationRecorder = EngineRecorderFake()
        let terminationEngine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [terminationRecorder]),
            store: terminationStore
        )
        terminationEngine.toggleRecording()
        await waitUntil { terminationEngine.state == .recording }

        terminationEngine.cleanup()

        XCTAssertEqual(terminationStore.removedURLs.count, 1)
        XCTAssertEqual(terminationStore.instanceCleanupCount, 1)
        XCTAssertEqual(terminationRecorder.cancelCount, 1)
    }

    func testCancellationCleansAudioFromEveryFileOwningActiveState() async {
        for activeState in FileOwningActiveState.allCases {
            await assertSessionCleanup(from: activeState, action: .cancel)
        }
    }

    func testApplicationTerminationCleansAudioFromEveryFileOwningActiveState() async {
        for activeState in FileOwningActiveState.allCases {
            await assertSessionCleanup(from: activeState, action: .terminateApplication)
        }
    }

    func testApplicationTerminationDuringTranscriptionSynchronouslyKillsSIGTERMIgnoringChild() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-EngineTermination-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let processPIDFile = fixtureDirectory.appendingPathComponent("whisper.pid")
        let executable = try makeSIGTERMIgnoringExecutable(
            in: fixtureDirectory,
            processPIDFile: processPIDFile
        )
        let dependencies = ResolvedWhisperDependencies(
            binaryURL: executable,
            modelURL: fixtureDirectory.appendingPathComponent("model.bin")
        )
        let processRunner = FoundationProcessRunner(terminationGracePeriod: 30)
        let transcriber = WhisperTranscriber(
            dependencyResolver: EngineDependencyResolverFake(result: .resolved(dependencies)),
            audioValidator: EngineAudioValidatorFake(result: .valid(duration: 1)),
            processRunner: processRunner,
            timeout: 30
        )
        let store = EngineFileStoreFake()
        let engine = makeEngine(store: store, transcriber: transcriber)
        let hotKeyController = HotKeyController(service: EngineHotKeyServiceFake())
        let appDelegate = AppDelegate(
            transcriptionEngine: engine,
            hotKeyController: hotKeyController
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        engine.toggleRecording()
        await waitUntil { engine.state == .transcribing }
        let processIdentifier = try await waitForProcessIdentifier(from: processPIDFile)

        appDelegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )

        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs)
        XCTAssertEqual(store.instanceCleanupCount, 1)
    }

    private func makeEngine(
        preflight: EnginePreflightFake = EnginePreflightFake(),
        permission: EnginePermissionFake = EnginePermissionFake(),
        factory: EngineRecorderFactoryFake = EngineRecorderFactoryFake(),
        store: EngineFileStoreFake = EngineFileStoreFake(),
        transcriber: any WhisperTranscribing = EngineTranscriberFake(),
        delivery: EngineDeliveryFake = EngineDeliveryFake()
    ) -> TranscriptionEngine {
        TranscriptionEngine(
            permissionProvider: permission,
            recorderFactory: factory,
            recordingFileStore: store,
            dependencyPreflight: preflight,
            transcriber: transcriber,
            textDelivery: delivery,
            performStartupCleanup: false
        )
    }

    private enum FileOwningActiveState: CaseIterable, Equatable {
        case stopping
        case transcribing
        case delivering
    }

    private enum SessionCleanupAction: Equatable {
        case cancel
        case terminateApplication
    }

    private func assertSessionCleanup(
        from activeState: FileOwningActiveState,
        action: SessionCleanupAction,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let recorder = EngineRecorderFake()
        let transcriber: EngineTranscriberFake
        let delivery: EngineDeliveryFake
        switch activeState {
        case .stopping:
            recorder.immediateStopOutcome = nil
            transcriber = EngineTranscriberFake()
            delivery = EngineDeliveryFake()
        case .transcribing:
            transcriber = EngineTranscriberFake(outcome: nil)
            delivery = EngineDeliveryFake()
        case .delivering:
            transcriber = EngineTranscriberFake(outcome: .success("fixture transcript"))
            delivery = EngineDeliveryFake(outcome: nil)
        }

        let store = EngineFileStoreFake()
        let engine = makeEngine(
            factory: EngineRecorderFactoryFake(recorders: [recorder]),
            store: store,
            transcriber: transcriber,
            delivery: delivery
        )
        engine.toggleRecording()
        await waitUntil { engine.state == .recording }
        engine.toggleRecording()

        switch activeState {
        case .stopping:
            await waitUntil { engine.state == .stopping && recorder.stopCount == 1 }
        case .transcribing:
            await waitUntil {
                engine.state == .transcribing && transcriber.invocationCount == 1
            }
        case .delivering:
            await waitUntil {
                engine.state == .delivering && delivery.deliveredTexts.count == 1
            }
        }

        switch action {
        case .cancel:
            engine.cancelCurrentOperation()
        case .terminateApplication:
            engine.cleanup()
        }

        XCTAssertEqual(store.allocatedURLs.count, 1, file: file, line: line)
        XCTAssertEqual(store.removedURLs, store.allocatedURLs, file: file, line: line)
        XCTAssertEqual(
            store.instanceCleanupCount,
            action == .terminateApplication ? 1 : 0,
            file: file,
            line: line
        )
        XCTAssertEqual(
            transcriber.synchronousTerminationCount,
            action == .terminateApplication ? 1 : 0,
            file: file,
            line: line
        )

        if activeState == .delivering {
            delivery.resolve(.inserted)
            await spinMainActor()
        }
    }

    private func makeSIGTERMIgnoringExecutable(
        in directory: URL,
        processPIDFile: URL
    ) throws -> URL {
        let executable = directory.appendingPathComponent("whisper-cli")
        let script = """
        #!/bin/sh
        set -eu
        trap '' TERM
        printf '%s' "$$" > '\(processPIDFile.path)'
        while :; do :; done
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        return executable
    }

    private func readProcessIdentifier(from url: URL) throws -> pid_t {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processIdentifier = pid_t(value) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return processIdentifier
    }

    private func waitForProcessIdentifier(from url: URL) async throws -> pid_t {
        for _ in 0..<200 {
            if let processIdentifier = try? readProcessIdentifier(from: url) {
                return processIdentifier
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        XCTFail("Condition was not reached", file: file, line: line)
    }

    private func spinMainActor() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

private struct EngineDependencyResolverFake: WhisperDependencyResolving {
    let result: WhisperDependencyResolution

    func resolveDependencies() -> WhisperDependencyResolution {
        result
    }
}

private struct EngineAudioValidatorFake: AudioValidating {
    let result: AudioValidationResult

    func validateAudio(at url: URL) -> AudioValidationResult {
        result
    }
}

@MainActor
private final class EngineHotKeyServiceFake: GlobalHotKeyService {
    func install(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotKeyInstallationError> {
        .success(())
    }

    func uninstall() -> Result<Void, HotKeyCleanupError> {
        .success(())
    }
}
