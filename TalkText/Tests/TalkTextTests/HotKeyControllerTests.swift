import Carbon.HIToolbox
import XCTest
@testable import TalkText

@MainActor
final class HotKeyControllerTests: XCTestCase {
    func testSuccessfulRegistrationBecomesAvailableAndInvokesAction() {
        let service = FakeHotKeyService(installResults: [.success(())])
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
            installResults: [.failure(.handlerRegistrationFailed(-50))]
        )
        let controller = HotKeyController(service: service)

        controller.register {}

        XCTAssertEqual(controller.availability, .handlerRegistrationFailed(-50))
        XCTAssertTrue(controller.availability.recoveryMessage?.contains("menu button still works") == true)
    }

    func testShortcutConflictIsUserVisible() {
        let service = FakeHotKeyService(
            installResults: [.failure(.shortcutRegistrationFailed(-9878))]
        )
        let controller = HotKeyController(service: service)

        controller.register {}

        XCTAssertEqual(controller.availability, .shortcutRegistrationFailed(-9878))
        XCTAssertTrue(controller.availability.recoveryMessage?.contains("conflicting shortcut") == true)
    }

    func testRetryUninstallsBeforeEveryAttemptAndDoesNotDuplicateRegistration() {
        let service = FakeHotKeyService(installResults: [
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

    func testReplacementAndRetryDoNotInstallWhileCleanupIsFailing() {
        let cleanupError = HotKeyCleanupError.shortcutUnregistrationFailed(-7001)
        let service = FakeHotKeyService(
            installResults: [.success(()), .success(())],
            uninstallResults: [
                .success(()),
                .failure(cleanupError),
                .failure(cleanupError),
                .success(()),
            ]
        )
        let controller = HotKeyController(service: service)
        var firstActionCount = 0
        var replacementActionCount = 0

        controller.register {
            firstActionCount += 1
        }
        controller.register {
            replacementActionCount += 1
        }

        XCTAssertEqual(controller.availability, .cleanupFailed(cleanupError))
        XCTAssertEqual(service.installCount, 1)
        service.invokeRegisteredAction()
        XCTAssertEqual(firstActionCount, 1)
        XCTAssertEqual(replacementActionCount, 0)

        controller.retry()

        XCTAssertEqual(controller.availability, .cleanupFailed(cleanupError))
        XCTAssertEqual(service.installCount, 1)

        controller.retry()
        service.invokeRegisteredAction()

        XCTAssertEqual(controller.availability, .registered)
        XCTAssertEqual(service.installCount, 2)
        XCTAssertEqual(service.maximumConcurrentInstallations, 1)
        XCTAssertEqual(firstActionCount, 1)
        XCTAssertEqual(replacementActionCount, 1)
    }

    func testUnregisterFailureIsVisibleAndCanBeRetried() {
        let cleanupError = HotKeyCleanupError.handlerRemovalFailed(-7002)
        let service = FakeHotKeyService(
            installResults: [.success(())],
            uninstallResults: [
                .success(()),
                .failure(cleanupError),
                .success(()),
            ]
        )
        let controller = HotKeyController(service: service)

        controller.register {}
        let failedCleanup = controller.unregister()

        assertCleanupFailure(failedCleanup, equals: cleanupError)
        XCTAssertEqual(controller.availability, .cleanupFailed(cleanupError))

        let successfulCleanup = controller.unregister()
        controller.retry()

        assertCleanupSuccess(successfulCleanup)
        XCTAssertEqual(controller.availability, .unregistered)
        XCTAssertEqual(service.installCount, 1)
        XCTAssertEqual(service.uninstallCount, 3)
    }

    func testUnregisterCleansUpAndPreventsRetryWithoutAnAction() {
        let service = FakeHotKeyService(installResults: [.success(())])
        let controller = HotKeyController(service: service)

        controller.register {}
        controller.unregister()
        controller.retry()

        XCTAssertEqual(controller.availability, .unregistered)
        XCTAssertEqual(service.installCount, 1)
        XCTAssertEqual(service.uninstallCount, 2)
    }

    func testCarbonUsesExclusiveRegistrationAndRollsBackHandlerAfterConflict() {
        let handler = eventHandlerRef(1)
        let api = FakeCarbonHotKeyAPI(
            handlerResults: [carbonResult(noErr, handler)],
            hotKeyResults: [carbonResult(OSStatus(eventHotKeyExistsErr), nil)]
        )
        let service = CarbonGlobalHotKeyService(api: api)

        let result = service.install {}

        assertInstallationFailure(
            result,
            equals: .shortcutRegistrationFailed(OSStatus(eventHotKeyExistsErr))
        )
        XCTAssertEqual(api.registrationOptions, [OptionBits(kEventHotKeyExclusive)])
        XCTAssertEqual(api.removedEventHandlers, [handler])
        XCTAssertTrue(api.unregisteredHotKeys.isEmpty)
    }

    func testCarbonRollbackFailureBlocksInstallationUntilHandlerRemovalSucceeds() {
        let firstHandler = eventHandlerRef(1)
        let secondHandler = eventHandlerRef(2)
        let hotKey = eventHotKeyRef(3)
        let cleanupError = HotKeyCleanupError.handlerRemovalFailed(-7003)
        let api = FakeCarbonHotKeyAPI(
            handlerResults: [
                carbonResult(noErr, firstHandler),
                carbonResult(noErr, secondHandler),
            ],
            hotKeyResults: [
                carbonResult(OSStatus(eventHotKeyExistsErr), nil),
                carbonResult(noErr, hotKey),
            ],
            removeStatuses: [-7003, -7003, noErr]
        )
        let service = CarbonGlobalHotKeyService(api: api)

        let failedRollback = service.install {}
        let blockedRetry = service.install {}

        assertInstallationFailure(failedRollback, equals: .cleanupFailed(cleanupError))
        assertInstallationFailure(blockedRetry, equals: .cleanupFailed(cleanupError))
        XCTAssertEqual(api.installedEventHandlerCount, 1)
        XCTAssertEqual(api.registrationOptions.count, 1)

        let successfulRetry = service.install {}

        assertInstallationSuccess(successfulRetry)
        XCTAssertEqual(api.installedEventHandlerCount, 2)
        XCTAssertEqual(api.registrationOptions.count, 2)
        XCTAssertEqual(
            api.removedEventHandlers,
            [firstHandler, firstHandler, firstHandler]
        )
    }

    func testCarbonUnregisterFailureRetainsLifecycleUntilCleanupSucceeds() {
        let handler = eventHandlerRef(1)
        let hotKey = eventHotKeyRef(2)
        let api = FakeCarbonHotKeyAPI(
            handlerResults: [carbonResult(noErr, handler)],
            hotKeyResults: [carbonResult(noErr, hotKey)],
            unregisterStatuses: [-7004, noErr]
        )
        let service = CarbonGlobalHotKeyService(api: api)
        var token: CallbackLifetimeToken? = CallbackLifetimeToken()
        let weakToken = WeakReference(token)

        let installation = service.install { [token] in
            _ = token
        }
        token = nil
        let failedCleanup = service.uninstall()

        assertInstallationSuccess(installation)
        assertCleanupFailure(
            failedCleanup,
            equals: .shortcutUnregistrationFailed(-7004)
        )
        XCTAssertNotNil(weakToken.value)
        XCTAssertEqual(api.unregisteredHotKeys, [hotKey])
        XCTAssertTrue(api.removedEventHandlers.isEmpty)

        let successfulCleanup = service.uninstall()

        assertCleanupSuccess(successfulCleanup)
        XCTAssertNil(weakToken.value)
        XCTAssertEqual(api.unregisteredHotKeys, [hotKey, hotKey])
        XCTAssertEqual(api.removedEventHandlers, [handler])
    }

    func testCarbonHandlerRemovalFailureRetainsContextAndDoesNotUnregisterTwice() {
        let handler = eventHandlerRef(1)
        let hotKey = eventHotKeyRef(2)
        let api = FakeCarbonHotKeyAPI(
            handlerResults: [carbonResult(noErr, handler)],
            hotKeyResults: [carbonResult(noErr, hotKey)],
            removeStatuses: [-7005, noErr]
        )
        let service = CarbonGlobalHotKeyService(api: api)
        var token: CallbackLifetimeToken? = CallbackLifetimeToken()
        let weakToken = WeakReference(token)

        let installation = service.install { [token] in
            _ = token
        }
        token = nil
        let failedCleanup = service.uninstall()

        assertInstallationSuccess(installation)
        assertCleanupFailure(failedCleanup, equals: .handlerRemovalFailed(-7005))
        XCTAssertNotNil(weakToken.value)
        XCTAssertEqual(api.unregisteredHotKeys, [hotKey])
        XCTAssertEqual(api.removedEventHandlers, [handler])

        let successfulCleanup = service.uninstall()

        assertCleanupSuccess(successfulCleanup)
        XCTAssertNil(weakToken.value)
        XCTAssertEqual(api.unregisteredHotKeys, [hotKey])
        XCTAssertEqual(api.removedEventHandlers, [handler, handler])
    }

    func testCarbonReplacementWaitsForUnregisterFailureToClear() {
        let firstHandler = eventHandlerRef(1)
        let secondHandler = eventHandlerRef(2)
        let firstHotKey = eventHotKeyRef(3)
        let secondHotKey = eventHotKeyRef(4)
        let cleanupError = HotKeyCleanupError.shortcutUnregistrationFailed(-7006)
        let api = FakeCarbonHotKeyAPI(
            handlerResults: [
                carbonResult(noErr, firstHandler),
                carbonResult(noErr, secondHandler),
            ],
            hotKeyResults: [
                carbonResult(noErr, firstHotKey),
                carbonResult(noErr, secondHotKey),
            ],
            unregisterStatuses: [-7006, -7006, noErr]
        )
        let service = CarbonGlobalHotKeyService(api: api)
        let controller = HotKeyController(service: service)

        controller.register {}
        controller.register {}
        controller.retry()

        XCTAssertEqual(controller.availability, .cleanupFailed(cleanupError))
        XCTAssertEqual(api.installedEventHandlerCount, 1)
        XCTAssertEqual(api.registrationOptions.count, 1)

        controller.retry()

        XCTAssertEqual(controller.availability, .registered)
        XCTAssertEqual(api.installedEventHandlerCount, 2)
        XCTAssertEqual(api.registrationOptions.count, 2)
        XCTAssertEqual(
            api.unregisteredHotKeys,
            [firstHotKey, firstHotKey, firstHotKey]
        )
        XCTAssertEqual(api.removedEventHandlers, [firstHandler])
    }

    func testTerminationCleanupReleasesCarbonHotKeyAndHandler() {
        let handler = eventHandlerRef(1)
        let hotKey = eventHotKeyRef(2)
        let api = FakeCarbonHotKeyAPI(
            handlerResults: [carbonResult(noErr, handler)],
            hotKeyResults: [carbonResult(noErr, hotKey)]
        )
        let service = CarbonGlobalHotKeyService(api: api)
        let controller = HotKeyController(service: service)

        controller.register {}
        let cleanup = controller.unregister()
        controller.retry()

        assertCleanupSuccess(cleanup)
        XCTAssertEqual(controller.availability, .unregistered)
        XCTAssertEqual(api.installedEventHandlerCount, 1)
        XCTAssertEqual(api.registrationOptions.count, 1)
        XCTAssertEqual(api.unregisteredHotKeys, [hotKey])
        XCTAssertEqual(api.removedEventHandlers, [handler])
    }
}

@MainActor
private final class FakeHotKeyService: GlobalHotKeyService {
    private var installResults: [Result<Void, HotKeyInstallationError>]
    private var uninstallResults: [Result<Void, HotKeyCleanupError>]
    private var action: (@MainActor @Sendable () -> Void)?
    private var activeInstallationCount = 0

    private(set) var installCount = 0
    private(set) var uninstallCount = 0
    private(set) var maximumConcurrentInstallations = 0

    init(
        installResults: [Result<Void, HotKeyInstallationError>],
        uninstallResults: [Result<Void, HotKeyCleanupError>] = []
    ) {
        self.installResults = installResults
        self.uninstallResults = uninstallResults
    }

    func install(
        action: @escaping @MainActor @Sendable () -> Void
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

    func uninstall() -> Result<Void, HotKeyCleanupError> {
        uninstallCount += 1
        let result = uninstallResults.isEmpty ? .success(()) : uninstallResults.removeFirst()
        if case .success = result {
            activeInstallationCount = 0
            action = nil
        }
        return result
    }

    func invokeRegisteredAction() {
        action?()
    }
}

@MainActor
private final class FakeCarbonHotKeyAPI: CarbonHotKeyAPI {
    private var handlerResults: [CarbonHandleResult<EventHandlerRef>]
    private var hotKeyResults: [CarbonHandleResult<EventHotKeyRef>]
    private var unregisterStatuses: [OSStatus]
    private var removeStatuses: [OSStatus]

    private(set) var installedEventHandlerCount = 0
    private(set) var registrationOptions: [OptionBits] = []
    private(set) var unregisteredHotKeys: [EventHotKeyRef] = []
    private(set) var removedEventHandlers: [EventHandlerRef] = []

    init(
        handlerResults: [CarbonHandleResult<EventHandlerRef>],
        hotKeyResults: [CarbonHandleResult<EventHotKeyRef>],
        unregisterStatuses: [OSStatus] = [],
        removeStatuses: [OSStatus] = []
    ) {
        self.handlerResults = handlerResults
        self.hotKeyResults = hotKeyResults
        self.unregisterStatuses = unregisterStatuses
        self.removeStatuses = removeStatuses
    }

    func installEventHandler(
        context: UnsafeMutableRawPointer
    ) -> CarbonHandleResult<EventHandlerRef> {
        installedEventHandlerCount += 1
        guard !handlerResults.isEmpty else {
            XCTFail("Unexpected InstallEventHandler call")
            return carbonResult(OSStatus(eventInternalErr), nil)
        }
        return handlerResults.removeFirst()
    }

    func registerEventHotKey(
        options: OptionBits
    ) -> CarbonHandleResult<EventHotKeyRef> {
        registrationOptions.append(options)
        guard !hotKeyResults.isEmpty else {
            XCTFail("Unexpected RegisterEventHotKey call")
            return carbonResult(OSStatus(eventInternalErr), nil)
        }
        return hotKeyResults.removeFirst()
    }

    func unregisterEventHotKey(_ hotKey: EventHotKeyRef) -> OSStatus {
        unregisteredHotKeys.append(hotKey)
        return unregisterStatuses.isEmpty ? noErr : unregisterStatuses.removeFirst()
    }

    func removeEventHandler(_ eventHandler: EventHandlerRef) -> OSStatus {
        removedEventHandlers.append(eventHandler)
        return removeStatuses.isEmpty ? noErr : removeStatuses.removeFirst()
    }
}

private final class CallbackLifetimeToken: @unchecked Sendable {}

private final class WeakReference<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}

private func carbonResult<Handle>(
    _ status: OSStatus,
    _ handle: Handle?
) -> CarbonHandleResult<Handle> {
    CarbonHandleResult(status: status, handle: handle)
}

private func eventHandlerRef(_ value: Int) -> EventHandlerRef {
    EventHandlerRef(bitPattern: value)!
}

private func eventHotKeyRef(_ value: Int) -> EventHotKeyRef {
    EventHotKeyRef(bitPattern: value)!
}

private func assertInstallationSuccess(
    _ result: Result<Void, HotKeyInstallationError>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .success = result else {
        XCTFail("Expected installation to succeed, got \(result)", file: file, line: line)
        return
    }
}

private func assertInstallationFailure(
    _ result: Result<Void, HotKeyInstallationError>,
    equals expectedError: HotKeyInstallationError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let .failure(error) = result else {
        XCTFail("Expected installation failure, got \(result)", file: file, line: line)
        return
    }
    XCTAssertEqual(error, expectedError, file: file, line: line)
}

private func assertCleanupSuccess(
    _ result: Result<Void, HotKeyCleanupError>,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case .success = result else {
        XCTFail("Expected cleanup to succeed, got \(result)", file: file, line: line)
        return
    }
}

private func assertCleanupFailure(
    _ result: Result<Void, HotKeyCleanupError>,
    equals expectedError: HotKeyCleanupError,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case let .failure(error) = result else {
        XCTFail("Expected cleanup failure, got \(result)", file: file, line: line)
        return
    }
    XCTAssertEqual(error, expectedError, file: file, line: line)
}
