import AppKit
import Carbon.HIToolbox
import os

private let logger = Logger(subsystem: "com.joeblau.talktext", category: "hotkey")

// Store a global reference so the C callback can reach it
@MainActor private var sharedDelegate: AppDelegate?

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let transcriptionEngine = TranscriptionEngine()

    func applicationDidFinishLaunching(_ notification: Notification) {
        sharedDelegate = self
        registerCarbonHotKey()
    }

    private func registerCarbonHotKey() {
        // Install handler on the APPLICATION event target
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyHandler,
            1,
            &eventType,
            nil,
            nil
        )

        guard status == noErr else {
            logger.error("InstallEventHandler failed: \(status)")
            return
        }

        // Register Ctrl+Space
        let hotKeyID = EventHotKeyID(
            signature: OSType(0x54545854), // "TTXT"
            id: 1
        )
        var hotKeyRef: EventHotKeyRef?

        let regStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(controlKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if regStatus == noErr {
            logger.notice("Hotkey registered: Ctrl+Space")
        } else {
            logger.error("RegisterEventHotKey failed: \(regStatus)")
        }
    }
}

// C-function-pointer callback — cannot capture context, uses global
private func hotKeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    logger.notice("Hotkey pressed!")
    DispatchQueue.main.async { @MainActor in
        sharedDelegate?.transcriptionEngine.toggleRecording()
    }
    return noErr
}
