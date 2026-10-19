import AudioToolbox
import AVFoundation
import XCTest
@testable import TalkText

final class MicrophoneInputFormatTests: XCTestCase {
    func testConnect6InputPreservesFirstChannelThroughWAVCapture() throws {
        let format = try MicrophoneInput.captureFormat(for: hardwareFormat(channels: 18))
        XCTAssertEqual(format.channelCount, 18)
        XCTAssertEqual(format.sampleRate, 48_000)
        XCTAssertEqual(format.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(format.isInterleaved)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        buffer.frameLength = 4800
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<18 {
            for frame in 0..<4800 {
                channels[channel][frame] = channel == 0 ? 0.25 * sin(2 * .pi * 440 * Float(frame) / 48_000) : 1
            }
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try CapturedAudioSink(file: AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false))
        XCTAssertTrue(sink.beginCapturing())
        sink.append(buffer)
        XCTAssertEqual(sink.writtenBufferCount, 1)
        XCTAssertEqual(sink.peakLevel, -12.04, accuracy: 0.1, "The other 17 channels must not be mixed into the microphone")
        XCTAssertNil(sink.pendingErrorDiagnostic)
        XCTAssertTrue(sink.close())

        let recording = try AVAudioFile(forReading: url)
        XCTAssertEqual(recording.processingFormat.channelCount, 1)
        XCTAssertEqual(recording.processingFormat.sampleRate, 16_000)
        XCTAssertEqual(recording.length, 1600)
    }

    func testMonoAndStereoMicrophonesRemainSupported() throws {
        for count: UInt32 in [1, 2] {
            let format = try MicrophoneInput.captureFormat(for: hardwareFormat(channels: count))
            XCTAssertEqual(format.channelCount, count)
            XCTAssertEqual(format.sampleRate, 48_000)
            XCTAssertNotNil(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        }
    }

    func testInvalidHardwareFormatIsRejected() {
        for (rate, channels): (Double, UInt32) in [(0, 18), (.nan, 18), (.infinity, 18), (48_000, 0), (48_000, 65_536)] {
            XCTAssertThrowsError(try MicrophoneInput.captureFormat(for: hardwareFormat(sampleRate: rate, channels: channels))) { error in
                XCTAssertEqual(error as? AudioRecorderCreationError, .inputDeviceUnusable)
            }
        }
    }

    private func hardwareFormat(sampleRate: Double = 48_000, channels: UInt32) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }
}
