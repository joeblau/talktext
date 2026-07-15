import XCTest
@testable import TalkText

@MainActor
final class HotKeyControllerTests: XCTestCase {
    func testSuccessfulRegistrationBecomesAvailableAndInvokesAction() {
        let service = FakeHotKeyService(results: [.success(())])
        let controller = HotKeyController(service: service)
        var invocationCount = 0

        controller.register {
            invocationCount += 1
        }
        service.invokeRegisteredAction()

        XCTAssertEqual(controller.availability, .registered)
        XCTAssertEqual(service.installCount, 1)
        XCTAssertEqual(invocationCount, 1)
    }

    func testHandlerFailureIsUserVisible() {
        let service = FakeHotKeyService(
            results: [.failure(.handlerRegistrationFailed(-50))]
        )
        let controller = HotKeyController(service: service)

        controller.register {}

        XCTAssertEqual(controller.availability, .handlerRegistrationFailed(-50))
        XCTAssertTrue(controller.availability.recoveryMessage?.contains("menu button still works") == true)
    }

    func testShortcutConflictIsUserVisible() {
        let service = FakeHotKeyService(
            results: [.failure(.shortcutRegistrationFailed(-9878))]
        )
        let controller = HotKeyController(service: service)

        controller.register {}

        XCTAssertEqual(controller.availability, .shortcutRegistrationFailed(-9878))
        XCTAssertTrue(controller.availability.recoveryMessage?.contains("conflicting shortcut") == true)
    }

    func testRetryUninstallsBeforeEveryAttemptAndDoesNotDuplicateRegistration() {
        let service = FakeHotKeyService(results: [
            .failure(.shortcutRegistrationFailed(-9878)),
            .success(()),
        ])
        let controller = HotKeyController(service: service)

        controller.register {}
        controller.retry()

        XCTAssertEqual(controller.availability, .registered)
        XCTAssertEqual(service.installCount, 2)
        XCTAssertEqual(service.uninstallCount, 2)
        XCTAssertEqual(service.maximumConcurrentInstallations, 1)
    }

    func testUnregisterCleansUpAndPreventsRetryWithoutAnAction() {
        let service = FakeHotKeyService(results: [.success(())])
        let controller = HotKeyController(service: service)

        controller.register {}
        controller.unregister()
        controller.retry()

        XCTAssertEqual(controller.availability, .unregistered)
        XCTAssertEqual(service.installCount, 1)
        XCTAssertEqual(service.uninstallCount, 2)
    }
}

@MainActor
private final class FakeHotKeyService: GlobalHotKeyService {
    private var results: [Result<Void, HotKeyInstallationError>]
    private var action: (@MainActor @Sendable () -> Void)?
    private var activeInstallationCount = 0

    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    private(set) var maximumConcurrentInstallations = 0

    init(results: [Result<Void, HotKeyInstallationError>]) {
        self.results = results
    }

    func install(
        action: @escaping @MainActor @Sendable () -> Void
    ) -> Result<Void, HotKeyInstallationError> {
        installCount += 1
        self.action = action

        let result = results.isEmpty ? .success(()) : results.removeFirst()
        if case .success = result {
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

    func invokeRegisteredAction() {
        action?()
    }
}
