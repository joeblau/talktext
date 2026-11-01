@preconcurrency import AVFoundation
import Foundation

/// Cuts frame ranges out of a finished WAV snapshot so long dictations can
/// re-transcribe recent audio without decoding everything said before it.
enum RecordingAudioWindow {
    struct Layout: Equatable, Sendable {
        let frameCount: Int
        let sampleRate: Double
    }

    static func layout(of url: URL) -> Layout? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return nil }
        return Layout(frameCount: Int(file.length), sampleRate: file.processingFormat.sampleRate)
    }

    /// Writes `frames` of `source` as a standalone WAV in the source's format.
    static func write(from source: URL, frames: Range<Int>, to destination: URL) -> Bool {
        guard frames.lowerBound >= 0, !frames.isEmpty,
              let input = try? AVAudioFile(forReading: source),
              frames.upperBound <= Int(input.length) else { return false }
        do {
            let output = try AVAudioFile(
                forWriting: destination,
                settings: input.fileFormat.settings,
                commonFormat: input.processingFormat.commonFormat,
                interleaved: input.processingFormat.isInterleaved
            )
            input.framePosition = AVAudioFramePosition(frames.lowerBound)
            var remaining = frames.count
            while remaining > 0 {
                let count = AVAudioFrameCount(min(remaining, chunkFrames))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else {
                    return false
                }
                try input.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { return false }
                try output.write(from: buffer)
                remaining -= Int(buffer.frameLength)
            }
            return true
        } catch {
            return false
        }
    }

    /// The middle of the longest quiet run in `frames`, measured in 20 ms
    /// steps. Cutting mid-pause keeps a word from being split between two
    /// transcription passes.
    static func quietestFrame(in source: URL, searching frames: Range<Int>) -> Int? {
        guard frames.lowerBound >= 0, !frames.isEmpty,
              let input = try? AVAudioFile(forReading: source),
              frames.upperBound <= Int(input.length),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: input.processingFormat,
                  frameCapacity: AVAudioFrameCount(frames.count)
              ) else { return nil }
        input.framePosition = AVAudioFramePosition(frames.lowerBound)
        guard (try? input.read(into: buffer, frameCount: AVAudioFrameCount(frames.count))) != nil,
              let samples = buffer.floatChannelData?[0] else { return nil }
        let hop = max(1, Int(input.processingFormat.sampleRate * 0.02))
        let steps = Int(buffer.frameLength) / hop
        guard steps > 0 else { return nil }

        let energies = (0..<steps).map { step in
            (step * hop..<(step + 1) * hop).reduce(Float(0)) { $0 + samples[$1] * samples[$1] }
        }
        // Anything within twice the quietest step counts as the same pause.
        let threshold = (energies.min() ?? 0) * 2 + Float(hop) * 1e-8
        var bestRun = 0..<0
        var runStart: Int?
        for step in 0...steps {
            if step < steps, energies[step] <= threshold {
                if runStart == nil { runStart = step }
            } else if let start = runStart {
                if step - start > bestRun.count { bestRun = start..<step }
                runStart = nil
            }
        }
        let middleStep = (bestRun.lowerBound + bestRun.upperBound) / 2
        return frames.lowerBound + middleStep * hop + hop / 2
    }

    private static let chunkFrames = 16_384
}
