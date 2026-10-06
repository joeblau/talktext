@preconcurrency import AVFoundation
import Foundation
import os

private let cueLogger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "recording-cue")

/// Prepares a short, audible cue off the UI thread. System NSSound playback can
/// block for seconds while Bluetooth renegotiates, even for a tiny system sound.
final class RecordingCueAudio: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.joeblau.talktext.recording-cue", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var player: AVAudioPlayer?
    private let data: Data

    init(ascending: Bool) {
        data = Self.makeWave(ascending: ascending)
        queue.async { [self] in preparePlayer() }
    }

    func play() async {
        let identifier = lock.withLock { generation &+= 1; return generation }
        let duration = await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard isCurrent(identifier) else { continuation.resume(returning: 0.0); return }
                preparePlayer()
                guard let player else { continuation.resume(returning: 0.0); return }
                player.stop()
                player.currentTime = 0
                let played = player.play()
                if !played { cueLogger.error("Recording cue could not play") }
                continuation.resume(returning: played ? player.duration : 0.0)
            }
        }
        do {
            try await Task.sleep(for: .seconds(duration))
        } catch {
            stop(ifCurrent: identifier)
        }
    }

    func stop() {
        lock.withLock { generation &+= 1 }
        queue.async { [self] in player?.stop() }
    }

    private func stop(ifCurrent identifier: UInt64) {
        queue.async { [self] in
            if isCurrent(identifier) { player?.stop() }
        }
    }

    private func isCurrent(_ identifier: UInt64) -> Bool { lock.withLock { generation == identifier } }

    private func preparePlayer() {
        guard player == nil else { return }
        do {
            let player = try AVAudioPlayer(data: data)
            player.volume = 0.85
            player.prepareToPlay()
            self.player = player
        } catch {
            cueLogger.error("Recording cue could not be prepared")
        }
    }

    /// Two notes with smooth attack/release; fixed duration keeps capture latency
    /// predictable and avoids clipping a longer system sound in mid-playback.
    static func makeWave(ascending: Bool) -> Data {
        let sampleRate = 24_000
        let noteFrames = 960
        let frameCount = noteFrames * 2
        var data = Data()
        func append(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36 + frameCount * 2))
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))
        append(UInt16(2))
        append(UInt16(16))
        data.append(contentsOf: "data".utf8)
        append(UInt32(frameCount * 2))
        for index in 0..<frameCount {
            let noteIndex = index % noteFrames
            let rising = (index < noteFrames) == ascending
            let frequency = rising ? 880.0 : 1174.66
            let envelope = min(1, Double(noteIndex) / 120, Double(noteFrames - 1 - noteIndex) / 240)
            let sample = sin(2 * .pi * frequency * Double(noteIndex) / Double(sampleRate)) * envelope * 0.4
            append(Int16(sample * Double(Int16.max)))
        }
        return data
    }
}
