import Foundation

/// A route notification is not a failed microphone. Keep the existing engine
/// open while Bluetooth settles, and restart it only when it actually stops.
@MainActor
enum AudioInputReadiness {
    struct Sample {
        let generation: UInt64
        let bufferCount: UInt64
        let isRunning: Bool
        let hasError: Bool
    }

    static func wait(
        after baselineBufferCount: UInt64,
        generation: UInt64,
        requiredBuffers: UInt64 = 2,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50),
        settlingInterval: Duration = .milliseconds(200),
        sample: () -> Sample,
        restart: () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var expectedGeneration = generation
        var baseline = baselineBufferCount
        var stoppedSince: ContinuousClock.Instant?

        while clock.now < deadline {
            guard !Task.isCancelled else { return false }
            let current = sample()
            guard !current.hasError else { return false }
            if current.generation != expectedGeneration {
                expectedGeneration = current.generation
                baseline = current.bufferCount
                stoppedSince = clock.now
            }
            if current.isRunning {
                stoppedSince = nil
                if current.bufferCount >= baseline,
                   current.bufferCount - baseline >= requiredBuffers {
                    return true
                }
            } else if let stoppedAt = stoppedSince {
                if clock.now - stoppedAt >= settlingInterval {
                    guard !Task.isCancelled, restart() else { return false }
                    baseline = sample().bufferCount
                    stoppedSince = nil
                }
            } else {
                stoppedSince = clock.now
            }
            do {
                try await Task.sleep(for: pollInterval)
            } catch {
                return false
            }
        }
        return false
    }
}
