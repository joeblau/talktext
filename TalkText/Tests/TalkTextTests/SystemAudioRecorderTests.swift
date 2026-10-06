@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import XCTest
@testable import TalkText

@MainActor
final class SystemAudioRecorderTests: XCTestCase {
    func testKeyUpDuringAutomaticStopSharesFinalizationAndPreservesAudio() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let input = GatedMicrophoneInput()
        var events: [RecorderEvent] = []
        let recorder = try SystemAudioRecorder(url: url, inputResolver: RecorderInputResolver(), input: input) { events.append($0) }
        defer { recorder.cancel() }
        let prepared = await recorder.prepare()
        XCTAssertTrue(prepared)
        let started = await recorder.start(maximumDuration: 0.1)
        XCTAssertTrue(started)
        await input.gateNextClose()
        for _ in 0..<100 {
            if await input.closeBegan { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let closeBegan = await input.closeBegan
        XCTAssertTrue(closeBegan)
        XCTAssertFalse(recorder.isRecording)
        let keyUp = Task { await recorder.stop() }
        await Task.yield()
        await input.completeClose()
        let outcome = await keyUp.value
        XCTAssertEqual(outcome, .finished, "Key-up must share the automatic stop, not fail as not-recording")
        for _ in 0..<100 where events.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(events, [.maximumDurationReached])
        let recording = try AVAudioFile(forReading: url)
        XCTAssertGreaterThan(recording.length, 0)
        XCTAssertNil(recorder.isRecording ? "still recording" : nil)
    }
}

@MainActor
private final class RecorderInputResolver: AudioInputResolving {
    func resolveInputDevice() -> AudioInputDevice? { .init(uid: "fixture", name: "Fixture Microphone", deviceID: 42) }
}

private actor GatedMicrophoneInput: MicrophoneInputDriving {
    nonisolated let health = MicrophoneInputHealth()
    private var producer: Task<Void, Never>?
    private var gateClose = false
    private var closeContinuation: CheckedContinuation<Void, Never>?
    private(set) var closeBegan = false

    func open(deviceID: AudioDeviceID, sink: CapturedAudioSink) async throws {
        health.started()
        producer = Task {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)!
            buffer.frameLength = 960
            for index in 0..<960 {
                buffer.floatChannelData?[0][index] = 0.25
            }
            while !Task.isCancelled {
                sink.append(buffer)
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
    }

    func gateNextClose() { gateClose = true }

    func close() async {
        producer?.cancel()
        producer = nil
        health.stopped()
        if gateClose {
            closeBegan = true
            await withCheckedContinuation { closeContinuation = $0 }
        }
    }

    func completeClose() {
        gateClose = false
        closeContinuation?.resume()
        closeContinuation = nil
    }

    nonisolated func cancel() {
        health.cancel()
        Task { await completeClose(); await close() }
    }
}
