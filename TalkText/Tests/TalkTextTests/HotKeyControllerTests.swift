import XCTest
@testable import TalkText

@MainActor
final class HotKeyControllerTests: XCTestCase {
    func testSingleTapDoesNothing() {
        let harness = Harness(start: 10)

        harness.service.send(.pressed)
        harness.clock.value = 10.05
        harness.service.send(.released)
        harness.timer.fire()

        XCTAssertTrue(harness.intents.isEmpty)
    }

    func testHoldStartsOnThresholdAndStopsOnRelease() {
        let harness = Harness(start: 20)

        harness.service.send(.pressed)
        XCTAssertTrue(harness.intents.isEmpty)

        harness.clock.value = 20.25
        harness.timer.fire()
        XCTAssertEqual(harness.intents, [.start])

        harness.clock.value = 21.4
        harness.service.send(.released)
        XCTAssertEqual(harness.intents, [.start, .stop])
    }

    func testDoubleTapLatchesRecordingAndSurvivesRelease() {
        let harness = Harness(start: 30)

        harness.service.send(.pressed)
        harness.clock.value = 30.05
        harness.service.send(.released)
        harness.timer.fire()
        XCTAssertTrue(harness.intents.isEmpty)

        harness.clock.value = 30.1
        harness.service.send(.pressed)
        XCTAssertEqual(harness.intents, [.start])

        harness.clock.value = 30.15
        harness.service.send(.released)
        harness.timer.fire()
        XCTAssertEqual(harness.intents, [.start])
    }

    func testAnyPressStopsALatchedRecording() {
        let harness = Harness(start: 40)
        harness.latchRecording()

        harness.clock.value = 45
        harness.service.send(.pressed)
        XCTAssertEqual(harness.intents, [.start, .stop])

        harness.clock.value = 45.05
        harness.service.send(.released)
        harness.timer.fire()
        XCTAssertEqual(harness.intents, [.start, .stop])
    }

    func testHoldingAfterALatchIsANewGesture() {
        let harness = Harness(start: 50)
        harness.latchRecording()

        harness.clock.value = 55
        harness.service.send(.pressed)
        harness.clock.value = 55.05
        harness.service.send(.released)
        harness.clock.value = 56
        harness.service.send(.pressed)
        harness.clock.value = 56.25
        harness.timer.fire()

        XCTAssertEqual(harness.intents, [.start, .stop, .start])
    }

    func testLateSecondTapBecomesANewFirstTap() {
        let harness = Harness(start: 60)

        harness.service.send(.pressed)
        harness.clock.value = 60.05
        harness.service.send(.released)
        harness.clock.value = 60.5
        harness.service.send(.pressed)
        harness.clock.value = 60.55
        harness.service.send(.released)
        harness.timer.fire()

        XCTAssertTrue(harness.intents.isEmpty)
    }

    func testReleaseBeforeHoldThresholdCancelsThePendingStart() {
        let harness = Harness(start: 70)

        harness.service.send(.pressed)
        harness.clock.value = 70.1
        harness.service.send(.released)
        harness.timer.fire()

        XCTAssertTrue(harness.intents.isEmpty)
        XCTAssertEqual(harness.timer.cancelCount, 2)
    }

    func testDuplicateModifierEventsDoNotDuplicateIntents() {
        let harness = Harness(start: 80)

        harness.service.send(.pressed)
        harness.service.send(.pressed)
        harness.clock.value = 80.25
        harness.timer.fire()
        harness.timer.fire()
        harness.clock.value = 81
        harness.service.send(.released)
        harness.service.send(.released)

        XCTAssertEqual(harness.intents, [.start, .stop])
    }

    func testExternalSessionEndResetsGesture() {
        let harness = Harness(start: 90)

        harness.service.send(.pressed)
        harness.clock.value = 90.25
        harness.timer.fire()
        harness.controller.recordingSessionDidEnd()
        harness.clock.value = 90.5
        harness.service.send(.released)
        harness.clock.value = 91
        harness.service.send(.pressed)
        harness.clock.value = 91.05
        harness.service.send(.released)
        harness.timer.fire()

        XCTAssertEqual(harness.intents, [.start])
    }

    func testExternalSessionEndResetsALatchedRecording() {
        let harness = Harness(start: 100)
        harness.latchRecording()

        harness.controller.recordingSessionDidEnd()
        harness.clock.value = 101
        harness.service.send(.pressed)
        harness.clock.value = 101.25
        harness.timer.fire()

        XCTAssertEqual(harness.intents, [.start, .start])
    }

    func testRegistrationFailureIsVisibleAndRetryCanRecover() {
        let service = FakeHotKeyService(installResults: [
            .failure(.monitorRegistrationFailed),
            .success(()),
        ])
        let controller = HotKeyController(service: service, holdTimer: FakeHoldTimer())

        controller.register { _ in }

        XCTAssertEqual(controller.availability, .monitorRegistrationFailed)
        XCTAssertTrue(controller.availability.recoveryMessage?.contains("Accessibility") == true)

        controller.retry()

        XCTAssertEqual(controller.availability, .registered)
        XCTAssertEqual(service.installCount, 2)
        XCTAssertEqual(service.uninstallCount, 2)
    }

    func testReplacementUninstallsBeforeRegisteringNewAction() {
        let harness = Harness(start: 110)
        var replacementIntents: [RecordingIntent] = []

        harness.controller.register { replacementIntents.append($0) }
        harness.service.send(.pressed)
        harness.clock.value = 110.25
        harness.timer.fire()

        XCTAssertTrue(harness.intents.isEmpty)
        XCTAssertEqual(replacementIntents, [.start])
        XCTAssertEqual(harness.service.installCount, 2)
        XCTAssertEqual(harness.service.uninstallCount, 2)
        XCTAssertEqual(harness.service.maximumConcurrentInstallations, 1)
    }

    func testUnregisterPreventsRetryAndFurtherGestures() {
        let harness = Harness(start: 120)

        harness.controller.unregister()
        harness.controller.retry()
        harness.service.send(.pressed)
        harness.timer.fire()
        harness.service.send(.released)

        XCTAssertTrue(harness.intents.isEmpty)
        XCTAssertEqual(harness.controller.availability, .unregistered)
        XCTAssertEqual(harness.service.installCount, 1)
        XCTAssertEqual(harness.service.uninstallCount, 2)
    }
}

@MainActor
private final class Harness {
    let service = FakeHotKeyService()
    let timer = FakeHoldTimer()
    let clock: TestTimeSource
    let controller: HotKeyController
    private(set) var intents: [RecordingIntent] = []

    init(start: TimeInterval) {
        let clock = TestTimeSource(start)
        self.clock = clock
        controller = HotKeyController(
            service: service,
            holdTimer: timer,
            holdThreshold: 0.25,
            doubleTapInterval: 0.35,
            now: { clock.value }
        )
        controller.register { [weak self] intent in
            self?.intents.append(intent)
        }
    }

    /// Two quick taps: the second press latches recording on.
    func latchRecording() {
        service.send(.pressed)
        clock.value += 0.05
        service.send(.released)
        timer.fire()
        clock.value += 0.05
        service.send(.pressed)
        clock.value += 0.05
        service.send(.released)
    }
}

@MainActor
private final class TestTimeSource {
    var value: TimeInterval

    init(_ value: TimeInterval) {
        self.value = value
    }
}

@MainActor
private final class FakeHoldTimer: HoldTimerScheduling {
    private var pendingAction: (@MainActor @Sendable () -> Void)?

    private(set) var scheduleCount = 0
    private(set) var cancelCount = 0
    private(set) var lastDelay: TimeInterval?

    func schedule(after delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) {
        scheduleCount += 1
        lastDelay = delay
        pendingAction = action
    }

    func cancel() {
        cancelCount += 1
        pendingAction = nil
    }

    /// Runs the pending hold callback, if the controller still has one armed.
    func fire() {
        let action = pendingAction
        pendingAction = nil
        action?()
    }
}

@MainActor
private final class FakeHotKeyService: GlobalHotKeyService {
    private var installResults: [Result<Void, HotKeyInstallationError>]
    private var action: (@MainActor @Sendable (RightOptionKeyPhase) -> Void)?
    private var activeInstallationCount = 0

    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    private(set) var maximumConcurrentInstallations = 0

    init(installResults: [Result<Void, HotKeyInstallationError>] = []) {
        self.installResults = installResults
    }

    func install(
        action: @escaping @MainActor @Sendable (RightOptionKeyPhase) -> Void
    ) -> Result<Void, HotKeyInstallationError> {
        installCount += 1
        let result = installResults.isEmpty ? .success(()) : installResults.removeFirst()
        if case .success = result {
            self.action = action
            activeInstallationCount += 1
            maximumConcurrentInstallations = max(
                maximumConcurrentInstallations,
                activeInstallationCount
            )
        }
        return result
    }

    func uninstall() {
        uninstallCount += 1
        activeInstallationCount = 0
        action = nil
    }

    func send(_ phase: RightOptionKeyPhase) {
        action?(phase)
    }
}
