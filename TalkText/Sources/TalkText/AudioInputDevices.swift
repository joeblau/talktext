import AppKit
import Combine
import CoreAudio
import Foundation
import os

private let audioInputLogger = Logger(
    subsystem: AppIdentity.bundleIdentifier,
    category: "audio-input"
)

/// A CoreAudio device that can supply input channels. `uid` is stable across
/// reboots and reconnects, so it is what TalkText persists; `deviceID` is only
/// valid for the current process lifetime.
struct AudioInputDevice: Equatable, Identifiable, Sendable {
    let uid: String
    let name: String
    let deviceID: AudioDeviceID

    var id: String { uid }
}

/// Which input TalkText records from. `.systemDefault` follows System Settings,
/// which is what most users want until they keep a dedicated interface plugged in.
enum AudioInputPreference: Hashable, Sendable {
    case systemDefault
    case device(uid: String)

    var uid: String? {
        switch self {
        case .systemDefault: nil
        case let .device(uid): uid
        }
    }
}

@MainActor
protocol AudioInputDeviceListing: AnyObject {
    func inputDevices() -> [AudioInputDevice]
    func systemDefaultInputDevice() -> AudioInputDevice?
}

/// Resolves the device a new recording should open.
@MainActor
protocol AudioInputResolving: AnyObject {
    func resolveInputDevice() -> AudioInputDevice?
}

@MainActor
final class CoreAudioInputDeviceLister: AudioInputDeviceListing {
    func inputDevices() -> [AudioInputDevice] {
        CoreAudioInput.allDeviceIDs()
            .filter { CoreAudioInput.inputChannelCount(of: $0) > 0 }
            .compactMap(CoreAudioInput.describe(deviceID:))
    }

    func systemDefaultInputDevice() -> AudioInputDevice? {
        guard let deviceID = CoreAudioInput.defaultInputDeviceID() else {
            return nil
        }
        return CoreAudioInput.describe(deviceID: deviceID)
    }
}

/// Publishes the input-device list and the user's choice, and persists the
/// choice so it survives relaunches.
@MainActor
final class AudioInputSelection: ObservableObject, AudioInputResolving {
    static let preferenceDefaultsKey = "TalkTextSelectedInputDeviceUID"

    @Published private(set) var devices: [AudioInputDevice] = []
    @Published private(set) var preference: AudioInputPreference

    private let lister: any AudioInputDeviceListing
    private let defaults: UserDefaults

    init(
        lister: any AudioInputDeviceListing = CoreAudioInputDeviceLister(),
        defaults: UserDefaults = .standard
    ) {
        self.lister = lister
        self.defaults = defaults
        preference = defaults.string(forKey: Self.preferenceDefaultsKey)
            .map(AudioInputPreference.device(uid:)) ?? .systemDefault
        refreshDevices()
    }

    func refreshDevices() {
        devices = lister.inputDevices()
    }

    func select(_ preference: AudioInputPreference) {
        self.preference = preference
        switch preference {
        case .systemDefault:
            defaults.removeObject(forKey: Self.preferenceDefaultsKey)
        case let .device(uid):
            defaults.set(uid, forKey: Self.preferenceDefaultsKey)
        }
        refreshDevices()
    }

    /// The device a recording started right now would open, or nil when the Mac
    /// reports no input at all.
    func resolveInputDevice() -> AudioInputDevice? {
        switch preference {
        case .systemDefault:
            return lister.systemDefaultInputDevice()
        case let .device(uid):
            if let match = lister.inputDevices().first(where: { $0.uid == uid }) {
                return match
            }
            // The chosen interface is unplugged. Recording from the system
            // default beats failing outright, and the menu still shows the
            // choice so it takes effect again on reconnect.
            audioInputLogger.notice("Selected input device is unavailable; falling back to system default")
            return lister.systemDefaultInputDevice()
        }
    }

    /// Name for the current choice, including the resolved device behind
    /// `.systemDefault` and a note when the chosen device is missing.
    var selectionSummary: String {
        switch preference {
        case .systemDefault:
            guard let device = lister.systemDefaultInputDevice() else {
                return "System Default (no input device)"
            }
            return "System Default (\(device.name))"
        case let .device(uid):
            guard let device = devices.first(where: { $0.uid == uid }) else {
                return "Unavailable device — using system default"
            }
            return device.name
        }
    }
}

/// Thin CoreAudio property wrappers. AVCaptureDevice can enumerate microphones
/// too, but recording runs through an AUHAL that is addressed by `AudioDeviceID`,
/// so TalkText reads the same layer it records from.
enum CoreAudioInput {
    static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs
        ) == noErr else {
            return []
        }
        return deviceIDs
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }
        return deviceID
    }

    static func describe(deviceID: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID) else {
            return nil
        }
        let name = stringProperty(kAudioObjectPropertyName, of: deviceID) ?? uid
        return AudioInputDevice(uid: uid, name: name, deviceID: deviceID)
    }

    static func inputChannelCount(of deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return 0
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr else {
            return 0
        }

        let bufferList = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        of deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else {
            return nil
        }
        return value as String
    }
}
