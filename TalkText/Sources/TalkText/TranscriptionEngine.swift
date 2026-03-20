@preconcurrency import AVFoundation
import ApplicationServices
import AppKit
import os

private let logger = Logger(subsystem: "com.joeblau.talktext", category: "engine")

private struct PasteTarget: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

// Audio recording happens off the main actor to avoid concurrency issues
private final class AudioRecorderHelper: NSObject, AVAudioRecorderDelegate, @unchecked Sendable {
    private var recorder: AVAudioRecorder?
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func start() -> Bool {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]

        try? FileManager.default.removeItem(at: url)

        do {
            recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder?.delegate = self
            recorder?.isMeteringEnabled = true
            let started = recorder?.record() ?? false
            if started {
                recorder?.updateMeters()
                let avg = recorder?.averagePower(forChannel: 0) ?? -999
                logger.notice("Recording started. Avg power: \(avg) dB")
            }
            return started
        } catch {
            logger.error("AVAudioRecorder init failed: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        recorder?.stop()
        recorder = nil
    }
}

@MainActor
final class TranscriptionEngine: ObservableObject {
    enum State: Equatable {
        case idle
        case recording
        case transcribing
    }

    @Published var state: State = .idle
    @Published var statusText: String = "Press Ctrl+Space to record"

    private var recorderHelper: AudioRecorderHelper?
    private let recordingURL: URL
    private let whisperBinaryPath: String
    private let modelPath: String
    private var currentSessionPasteTarget: PasteTarget?
    private var lastExternalPasteTarget: PasteTarget?
    private var activationObserver: NSObjectProtocol?

    init() {
        let tempDir = FileManager.default.temporaryDirectory
        self.recordingURL = tempDir.appendingPathComponent("whisper_recording.wav")

        let possibleBinaryPaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "\(NSHomeDirectory())/.local/bin/whisper-cli",
        ]
        self.whisperBinaryPath = possibleBinaryPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "/opt/homebrew/bin/whisper-cli"

        let possibleModelPaths = [
            "\(NSHomeDirectory())/Developer/joeblau/src/whisper/models/ggml-base.en.bin",
            "\(NSHomeDirectory())/.local/share/whisper/ggml-base.en.bin",
            "/opt/homebrew/share/whisper/models/ggml-base.en.bin",
        ]
        self.modelPath = possibleModelPaths.first { FileManager.default.fileExists(atPath: $0) } ?? "\(NSHomeDirectory())/Developer/joeblau/src/whisper/models/ggml-base.en.bin"

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor [weak self] in
                self?.rememberExternalApplication(application)
            }
        }

        if let application = currentExternalApplication() {
            rememberExternalApplication(application)
        }
    }

    func toggleRecording() {
        logger.notice("toggleRecording, state: \(String(describing: self.state))")
        switch state {
        case .idle:
            capturePasteTargetForCurrentSession()
            startRecording()
        case .recording:
            stopRecordingAndTranscribe()
        case .transcribing:
            break
        }
    }

    private func startRecording() {
        let authStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.notice("Mic auth: \(authStatus.rawValue)")

        switch authStatus {
        case .authorized:
            beginRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.beginRecording()
                    } else {
                        logger.error("Mic permission denied")
                        self?.statusText = "Microphone access denied"
                        self?.state = .idle
                    }
                }
            }
        case .denied, .restricted:
            logger.error("Mic denied/restricted")
            statusText = "Microphone blocked. Check System Settings > Privacy > Microphone"
            state = .idle
        @unknown default:
            beginRecording()
        }
    }

    private func beginRecording() {
        let helper = AudioRecorderHelper(url: recordingURL)
        recorderHelper = helper

        if helper.start() {
            state = .recording
            statusText = "Recording... Press Ctrl+Space to stop"
        } else {
            logger.error("Failed to start recording")
            statusText = "Failed to start recording"
            state = .idle
        }
    }

    private func stopRecordingAndTranscribe() {
        recorderHelper?.stop()
        recorderHelper = nil
        state = .transcribing
        statusText = "Transcribing..."

        let binaryPath = whisperBinaryPath
        let model = modelPath
        let audioPath = recordingURL.path

        Task {
            let text = await Self.runWhisper(binaryPath: binaryPath, modelPath: model, audioPath: audioPath)
            let cleaned = text?
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .replacingOccurrences(of: "(blank audio)", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            logger.notice("Transcription: '\(cleaned ?? "nil")'")

            if let cleaned = cleaned, !cleaned.isEmpty {
                if pasteText(cleaned) {
                    statusText = "Pasting... Press Ctrl+Space to record"
                } else {
                    statusText = "Copied. Enable Accessibility to auto-paste."
                }
            } else {
                statusText = "No speech detected. Press Ctrl+Space to record"
            }

            currentSessionPasteTarget = nil
            state = .idle
        }
    }

    nonisolated private static func runWhisper(binaryPath: String, modelPath: String, audioPath: String) async -> String? {
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            logger.error("whisper-cli not found at \(binaryPath)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            logger.error("Model not found at \(modelPath)")
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = [
            "--model", modelPath,
            "--file", audioPath,
            "--no-timestamps",
            "--threads", "4",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            return nil
        }
    }

    private func pasteText(_ text: String) -> Bool {
        logger.notice("Attempting to insert transcription: \(text)")

        guard ensureAccessibilityPermission() else {
            logger.error("Accessibility permission is required for auto-paste")
            return false
        }

        if insertTextIntoFocusedElement(text) {
            logger.notice("Inserted text into focused accessibility element")
            statusText = "Pasted! Press Ctrl+Space to record"
            return true
        }

        logger.notice("Direct accessibility insertion failed, falling back to synthetic paste")

        guard ensurePostEventPermission() else {
            logger.error("Event posting permission is required for synthetic paste fallback")
            return false
        }

        let pasteboard = NSPasteboard.general
        let originalItems = duplicatePasteboardItems(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transientChangeCount = pasteboard.changeCount

        guard let target = resolvedPasteTarget(),
              let targetApplication = runningApplication(for: target) else {
            logger.error("Unable to resolve a target app for paste")
            return false
        }

        logger.notice("Target app for paste: \(targetApplication.localizedName ?? "none"), pid: \(targetApplication.processIdentifier)")
        attemptPasteIntoFrontmostApplication(
            targetApplication,
            pasteboard: pasteboard,
            originalItems: originalItems,
            transientChangeCount: transientChangeCount,
            remainingRetries: 6
        )

        return true
    }

    private func attemptPasteIntoFrontmostApplication(
        _ targetApplication: NSRunningApplication,
        pasteboard: NSPasteboard,
        originalItems: [NSPasteboardItem]?,
        transientChangeCount: Int,
        remainingRetries: Int
    ) {
        targetApplication.activate(options: [.activateAllWindows])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier

            if frontmostPID != targetApplication.processIdentifier, remainingRetries > 0 {
                logger.notice("Paste target pid \(targetApplication.processIdentifier) is not frontmost yet. Retrying.")
                self.attemptPasteIntoFrontmostApplication(
                    targetApplication,
                    pasteboard: pasteboard,
                    originalItems: originalItems,
                    transientChangeCount: transientChangeCount,
                    remainingRetries: remainingRetries - 1
                )
                return
            }

            guard self.postPasteShortcut() else {
                logger.error("Failed to post paste shortcut")
                self.statusText = "Copied, but paste failed"
                return
            }

            let deliveredPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            logger.notice("Cmd+V sent to frontmost pid \(deliveredPID)")
            self.statusText = "Pasted! Press Ctrl+Space to record"

            self.restorePasteboardIfUnchanged(
                pasteboard,
                originalItems: originalItems,
                transientChangeCount: transientChangeCount
            )
        }
    }

    private func postPasteShortcut() -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)

        guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false),
              let commandUp = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
            return false
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        commandDown.post(tap: .cghidEventTap)
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        commandUp.post(tap: .cghidEventTap)
        return true
    }

    private func insertTextIntoFocusedElement(_ text: String) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElementValue: CFTypeRef?
        let focusError = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        )

        guard focusError == .success, let focusedElementValue else {
            logger.error("Unable to read focused accessibility element: \(focusError.rawValue)")
            return false
        }

        let focusedElement = unsafeDowncast(focusedElementValue, to: AXUIElement.self)

        var valueSettable = DarwinBoolean(false)
        let valueSettableError = AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &valueSettable
        )

        guard valueSettableError == .success, valueSettable.boolValue else {
            logger.error("Focused element does not expose a writable AXValue")
            return false
        }

        var currentValueRef: CFTypeRef?
        let currentValueError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            &currentValueRef
        )

        guard currentValueError == .success else {
            logger.error("Unable to read AXValue from focused element: \(currentValueError.rawValue)")
            return false
        }

        let currentValue = (currentValueRef as? String) ?? ""
        let currentNSString = currentValue as NSString
        let insertedNSString = text as NSString

        var selectedRange = CFRange(location: currentNSString.length, length: 0)
        if let selectionAXValue = copySelectedTextRange(from: focusedElement) {
            selectedRange = selectionAXValue
        }

        let safeLocation = max(0, min(selectedRange.location, currentNSString.length))
        let safeLength = max(0, min(selectedRange.length, currentNSString.length - safeLocation))
        let replacementRange = NSRange(location: safeLocation, length: safeLength)
        let updatedValue = currentNSString.replacingCharacters(in: replacementRange, with: text)

        let setValueError = AXUIElementSetAttributeValue(
            focusedElement,
            kAXValueAttribute as CFString,
            updatedValue as CFTypeRef
        )

        guard setValueError == .success else {
            logger.error("Unable to write AXValue to focused element: \(setValueError.rawValue)")
            return false
        }

        var insertionRange = CFRange(location: safeLocation + insertedNSString.length, length: 0)
        if let insertionAXValue = AXValueCreate(.cfRange, &insertionRange) {
            let selectionError = AXUIElementSetAttributeValue(
                focusedElement,
                kAXSelectedTextRangeAttribute as CFString,
                insertionAXValue
            )

            if selectionError != .success {
                logger.notice("Updated text, but could not restore insertion point: \(selectionError.rawValue)")
            }
        }

        return true
    }

    private func copySelectedTextRange(from element: AXUIElement) -> CFRange? {
        var selectedRangeRef: CFTypeRef?
        let selectionError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRangeRef
        )

        guard selectionError == .success,
              let selectedRangeRef,
              CFGetTypeID(selectedRangeRef) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = unsafeDowncast(selectedRangeRef, to: AXValue.self)
        guard AXValueGetType(rangeValue) == .cfRange else {
            return nil
        }

        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else {
            return nil
        }

        return selectedRange
    }

    private func ensurePostEventPermission() -> Bool {
        if CGPreflightPostEventAccess() {
            return true
        }

        return CGRequestPostEventAccess()
    }

    private func restorePasteboardIfUnchanged(
        _ pasteboard: NSPasteboard,
        originalItems: [NSPasteboardItem]?,
        transientChangeCount: Int
    ) {
        guard let originalItems, pasteboard.changeCount == transientChangeCount else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            guard pasteboard.changeCount == transientChangeCount else {
                return
            }

            pasteboard.clearContents()
            pasteboard.writeObjects(originalItems)
        }
    }

    private func duplicatePasteboardItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else {
            return nil
        }

        return items.map { item in
            let duplicate = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    duplicate.setData(data, forType: type)
                } else if let string = item.string(forType: type) {
                    duplicate.setString(string, forType: type)
                }
            }
            return duplicate
        }
    }

    private func capturePasteTargetForCurrentSession() {
        if let application = currentExternalApplication() {
            rememberExternalApplication(application)
            currentSessionPasteTarget = PasteTarget(
                processIdentifier: application.processIdentifier,
                bundleIdentifier: application.bundleIdentifier
            )
        } else {
            currentSessionPasteTarget = lastExternalPasteTarget
        }

        logger.notice("Captured paste target pid: \(self.currentSessionPasteTarget?.processIdentifier ?? -1)")
    }

    private func currentExternalApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return isTalkTextApplication(application) ? nil : application
    }

    private func rememberExternalApplication(_ application: NSRunningApplication) {
        guard !isTalkTextApplication(application) else {
            return
        }

        lastExternalPasteTarget = PasteTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private func resolvedPasteTarget() -> PasteTarget? {
        if let application = currentExternalApplication() {
            rememberExternalApplication(application)
        }

        return currentExternalPasteTarget() ?? currentSessionPasteTarget ?? lastExternalPasteTarget
    }

    private func currentExternalPasteTarget() -> PasteTarget? {
        guard let application = currentExternalApplication() else {
            return nil
        }

        return PasteTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    private func runningApplication(for target: PasteTarget) -> NSRunningApplication? {
        if let application = NSRunningApplication(processIdentifier: target.processIdentifier) {
            return application
        }

        guard let bundleIdentifier = target.bundleIdentifier else {
            return nil
        }

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    private func ensureAccessibilityPermission() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    private func isTalkTextApplication(_ application: NSRunningApplication) -> Bool {
        application.bundleIdentifier == Bundle.main.bundleIdentifier
    }
}
