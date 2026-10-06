import AVFoundation
import Foundation
import XCTest
@testable import TalkText

final class CapturedAudioSinkTests: XCTestCase {
    func testWarmupAudioIsDiscardedAndCapturedAudioIsResampledIntoReadableWAV() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try makeSink(at: url)
        let input = try makeBuffer(sampleRate: 48_000, amplitude: 0.25)
        sink.append(input)
        XCTAssertEqual(sink.receivedBufferCount, 1)
        XCTAssertEqual(sink.writtenBufferCount, 0)
        XCTAssertEqual(sink.peakLevel, -.infinity)
        XCTAssertTrue(sink.beginCapturing())
        for _ in 0..<10 {
            sink.append(input)
        }
        XCTAssertEqual(sink.writtenBufferCount, 10)
        XCTAssertEqual(sink.peakLevel, -12.04, accuracy: 0.1)
        XCTAssertNil(sink.pendingErrorDiagnostic)
        XCTAssertTrue(sink.close())
        let recording = try AVAudioFile(forReading: url)
        XCTAssertEqual(recording.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(recording.processingFormat.channelCount, 1)
        XCTAssertEqual(recording.length, 16_000)
        let data = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: recording.processingFormat, frameCapacity: AVAudioFrameCount(recording.length)))
        try recording.read(into: data)
        let samples = try XCTUnwrap(data.floatChannelData?[0])
        XCTAssertTrue((0..<Int(data.frameLength)).contains { abs(samples[$0]) > 0.2 })
        XCTAssertTrue((Int(data.frameLength) - 200..<Int(data.frameLength)).contains { abs(samples[$0]) > 0.2 }, "Stop must preserve the last audible samples")
    }

    func testSilentBuffersDoNotEraseTheCapturedSpeechPeak() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try makeSink(at: url)
        XCTAssertTrue(sink.beginCapturing())
        try sink.append(makeBuffer(sampleRate: 16_000, amplitude: 0.5))
        let peak = sink.peakLevel
        try sink.append(makeBuffer(sampleRate: 16_000, amplitude: 0))
        XCTAssertEqual(sink.peakLevel, peak)
        XCTAssertTrue(sink.close())
    }

    func testSampleRateChangeDoesNotLoseCaptureAndLateBuffersCannotReopenClosedFile() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try makeSink(at: url)
        XCTAssertTrue(sink.beginCapturing())
        for rate in [24_000.0, 48_000.0, 16_000.0] {
            for _ in 0..<3 {
                try sink.append(makeBuffer(sampleRate: rate, amplitude: 0.25))
            }
        }
        XCTAssertEqual(sink.writtenBufferCount, 9)
        XCTAssertNil(sink.pendingErrorDiagnostic)
        XCTAssertTrue(sink.close())
        let length = try AVAudioFile(forReading: url).length
        XCTAssertEqual(length, 14_400, "Resampling each route must preserve its full duration")
        try sink.append(makeBuffer(sampleRate: 48_000, amplitude: 1))
        XCTAssertEqual(sink.writtenBufferCount, 9)
        XCTAssertFalse(sink.beginCapturing())
        XCTAssertEqual(try AVAudioFile(forReading: url).length, length)
    }

    func testInputOnlyCancellationCannotBeClearedByALateStartup() {
        let health = MicrophoneInputHealth()
        health.started()
        XCTAssertTrue(health.isRunning)
        health.cancel()
        health.started()
        XCTAssertTrue(health.isCancelled)
        XCTAssertFalse(health.isRunning)
    }

    private func makeSink(at url: URL) throws -> CapturedAudioSink {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        return CapturedAudioSink(file: file)
    }

    private func makeBuffer(sampleRate: Double, amplitude: Float) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let frames = AVAudioFrameCount(sampleRate / 10)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) {
            samples[index] = amplitude * sin(2 * .pi * 440 * Float(index) / Float(sampleRate))
        }
        return buffer
    }

    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav") }
}
