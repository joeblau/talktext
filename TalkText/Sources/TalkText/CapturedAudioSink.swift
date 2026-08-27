@preconcurrency import AVFoundation
import Foundation

/// Owns everything the audio thread touches: the open file, the resampler, and
/// the running peak. Buffers arrive on a render thread, so every field lives
/// behind one lock instead of on the main actor.
final class CapturedAudioSink: @unchecked Sendable {
    var errorHandler: (@Sendable (RecorderErrorDiagnostic) -> Void)?

    private let lock = NSLock()
    private let processingFormat: AVAudioFormat
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var monoInputFormat: AVAudioFormat?
    private var peakAmplitude: Float = 0
    private var acceptingAudio = false
    private var receivedBuffers: UInt64 = 0
    private var successfulBufferWrites: UInt64 = 0
    private var errorDiagnostic: RecorderErrorDiagnostic?

    init(file: AVAudioFile) {
        self.file = file
        processingFormat = file.processingFormat
    }

    var peakLevel: Float {
        let amplitude = lock.withLock { peakAmplitude }
        return amplitude > 0 ? 20 * log10(amplitude) : -.infinity
    }

    var pendingErrorDiagnostic: RecorderErrorDiagnostic? {
        lock.withLock { errorDiagnostic }
    }

    /// Render callbacks prove the input route is live even while warm-up audio
    /// is intentionally discarded before the ready cue.
    var receivedBufferCount: UInt64 {
        lock.withLock { receivedBuffers }
    }

    /// Final startup readiness additionally requires a successful WAV write.
    var writtenBufferCount: UInt64 {
        lock.withLock { successfulBufferWrites }
    }

    func beginCapturing() -> Bool {
        lock.withLock {
            guard file != nil, errorDiagnostic == nil else {
                return false
            }
            peakAmplitude = 0
            acceptingAudio = true
            return true
        }
    }

    /// Caller already holds the lock. The resampler is built from the first
    /// buffer and rebuilt if the device changes rate mid-session, so the tap can
    /// deliver whatever format the hardware prefers.
    private func resampler(for sampleRate: Double) -> (AVAudioFormat, AVAudioConverter)? {
        if let monoInputFormat, let converter, monoInputFormat.sampleRate == sampleRate {
            return (monoInputFormat, converter)
        }

        guard let monoInputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        ),
            let converter = AVAudioConverter(from: monoInputFormat, to: processingFormat) else {
            return nil
        }
        self.monoInputFormat = monoInputFormat
        self.converter = converter
        return (monoInputFormat, converter)
    }

    /// Runs on the audio thread: take channel one, resample to 16 kHz, append.
    /// Level tracking happens here because silent capture is the one failure the
    /// finished file cannot report on its own.
    func append(_ buffer: AVAudioPCMBuffer) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return
        }

        let failure: RecorderErrorDiagnostic? = lock.withLock {
            receivedBuffers &+= 1
            guard acceptingAudio,
                  let file,
                  let (monoInputFormat, converter) = resampler(for: buffer.format.sampleRate),
                  let monoBuffer = AVAudioPCMBuffer(
                      pcmFormat: monoInputFormat,
                      frameCapacity: AVAudioFrameCount(frameCount)
                  ),
                  let destination = monoBuffer.floatChannelData?[0],
                  copyFirstChannel(of: buffer, into: destination, frameCount: frameCount) else {
                return nil
            }
            monoBuffer.frameLength = AVAudioFrameCount(frameCount)

            let ratio = processingFormat.sampleRate / monoInputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
            guard let converted = AVAudioPCMBuffer(
                pcmFormat: processingFormat,
                frameCapacity: capacity
            ) else {
                return nil
            }

            var suppliedBuffer = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if suppliedBuffer {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                suppliedBuffer = true
                inputStatus.pointee = .haveData
                return monoBuffer
            }

            guard status != .error else {
                return record(
                    failure: RecorderErrorDiagnostic(
                        domain: conversionError?.domain ?? "AVAudioConverter",
                        code: conversionError?.code ?? -1
                    )
                )
            }
            guard converted.frameLength > 0 else {
                return nil
            }

            do {
                try file.write(from: converted)
                successfulBufferWrites &+= 1
                return nil
            } catch {
                let nsError = error as NSError
                return record(
                    failure: RecorderErrorDiagnostic(domain: nsError.domain, code: nsError.code)
                )
            }
        }

        if let failure {
            errorHandler?(failure)
        }
    }

    /// Closing the file finalizes the RIFF length fields, so it has to happen
    /// before the transcriber reads the recording.
    func close() -> Bool {
        lock.withLock {
            guard file != nil else {
                return false
            }
            file = nil
            converter = nil
            acceptingAudio = false
            return true
        }
    }

    /// Caller already holds the lock.
    private func record(failure: RecorderErrorDiagnostic) -> RecorderErrorDiagnostic? {
        guard errorDiagnostic == nil else {
            return nil
        }
        errorDiagnostic = failure
        return failure
    }

    /// Interfaces such as an 18-input desk expose many channels while the mic
    /// sits on the first one, so TalkText takes channel one rather than asking
    /// the converter to downmix everything into a quieter average.
    private func copyFirstChannel(
        of buffer: AVAudioPCMBuffer,
        into destination: UnsafeMutablePointer<Float>,
        frameCount: Int
    ) -> Bool {
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        var peak: Float = 0

        if let channels = buffer.floatChannelData {
            let source = channels[0]
            for index in 0 ..< frameCount {
                let sample = source[index * stride]
                destination[index] = sample
                peak = max(peak, abs(sample))
            }
        } else if let channels = buffer.int16ChannelData {
            let source = channels[0]
            for index in 0 ..< frameCount {
                let sample = Float(source[index * stride]) / Float(Int16.max)
                destination[index] = sample
                peak = max(peak, abs(sample))
            }
        } else {
            return false
        }

        peakAmplitude = max(peakAmplitude, peak)
        return true
    }
}
