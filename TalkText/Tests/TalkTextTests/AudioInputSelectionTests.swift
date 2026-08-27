import XCTest
@testable import TalkText

@MainActor
final class AudioInputSelectionTests: XCTestCase {
    func testDefaultsToTheSystemInputWhenNothingWasChosen() {
        let lister = FakeInputDeviceLister(
            devices: [.builtIn, .interface],
            systemDefault: .builtIn
        )
        let selection = AudioInputSelection(lister: lister, defaults: makeDefaults())

        XCTAssertEqual(selection.preference, .systemDefault)
        XCTAssertEqual(selection.resolveInputDevice(), .builtIn)
        XCTAssertEqual(selection.selectionSummary, "System Default (MacBook Pro Microphone)")
    }

    func testChoosingADeviceResolvesToItAndSurvivesRelaunch() {
        let defaults = makeDefaults()
        let lister = FakeInputDeviceLister(
            devices: [.builtIn, .interface],
            systemDefault: .builtIn
        )
        let selection = AudioInputSelection(lister: lister, defaults: defaults)

        selection.select(.device(uid: AudioInputDevice.interface.uid))

        XCTAssertEqual(selection.resolveInputDevice(), .interface)
        XCTAssertEqual(selection.selectionSummary, "CONNECT 6")

        let relaunched = AudioInputSelection(lister: lister, defaults: defaults)
        XCTAssertEqual(relaunched.preference, .device(uid: AudioInputDevice.interface.uid))
        XCTAssertEqual(relaunched.resolveInputDevice(), .interface)
    }

    func testUnpluggedSelectionFallsBackToTheSystemDefaultWithoutForgettingTheChoice() {
        let defaults = makeDefaults()
        let lister = FakeInputDeviceLister(
            devices: [.builtIn, .interface],
            systemDefault: .builtIn
        )
        let selection = AudioInputSelection(lister: lister, defaults: defaults)
        selection.select(.device(uid: AudioInputDevice.interface.uid))

        lister.devices = [.builtIn]
        selection.refreshDevices()

        XCTAssertEqual(selection.resolveInputDevice(), .builtIn)
        XCTAssertEqual(selection.preference, .device(uid: AudioInputDevice.interface.uid))
        XCTAssertEqual(selection.selectionSummary, "Unavailable device — using system default")

        lister.devices = [.builtIn, .interface]
        selection.refreshDevices()
        XCTAssertEqual(selection.resolveInputDevice(), .interface)
    }

    func testSelectingSystemDefaultAgainClearsThePersistedChoice() {
        let defaults = makeDefaults()
        let lister = FakeInputDeviceLister(
            devices: [.builtIn, .interface],
            systemDefault: .builtIn
        )
        let selection = AudioInputSelection(lister: lister, defaults: defaults)

        selection.select(.device(uid: AudioInputDevice.interface.uid))
        selection.select(.systemDefault)

        XCTAssertNil(defaults.string(forKey: AudioInputSelection.preferenceDefaultsKey))
        XCTAssertEqual(selection.resolveInputDevice(), .builtIn)
    }

    func testNoInputDeviceResolvesToNothingSoRecordingCanExplainWhy() {
        let lister = FakeInputDeviceLister(devices: [], systemDefault: nil)
        let selection = AudioInputSelection(lister: lister, defaults: makeDefaults())

        XCTAssertNil(selection.resolveInputDevice())
        XCTAssertEqual(selection.selectionSummary, "System Default (no input device)")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "TalkTextTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

private extension AudioInputDevice {
    static let builtIn = AudioInputDevice(
        uid: "BuiltInMicrophoneDevice",
        name: "MacBook Pro Microphone",
        deviceID: 88
    )

    static let interface = AudioInputDevice(
        uid: "AppleUSBAudioEngine:Lewitt GmbH:CONNECT 6",
        name: "CONNECT 6",
        deviceID: 92
    )
}

@MainActor
private final class FakeInputDeviceLister: AudioInputDeviceListing {
    var devices: [AudioInputDevice]
    var systemDefault: AudioInputDevice?

    init(devices: [AudioInputDevice], systemDefault: AudioInputDevice?) {
        self.devices = devices
        self.systemDefault = systemDefault
    }

    func inputDevices() -> [AudioInputDevice] {
        devices
    }

    func systemDefaultInputDevice() -> AudioInputDevice? {
        systemDefault
    }
}
