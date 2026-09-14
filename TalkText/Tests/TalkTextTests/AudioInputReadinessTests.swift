import XCTest
@testable import TalkText

@MainActor
final class AudioInputReadinessTests: XCTestCase {
    func testConfigurationChangeWithContinuingBuffersDoesNotReopenMicrophone() async {
        var count: UInt64 = 0
        var restartCount = 0
        let ready = await AudioInputReadiness.wait(
            after: 0, generation: 0, requiredBuffers: 2,
            timeout: .seconds(1), pollInterval: .milliseconds(1),
            sample: {
                count += 1
                return .init(generation: 1, bufferCount: count, isRunning: true, hasError: false)
            },
            restart: { restartCount += 1; return true }
        )
        XCTAssertTrue(ready)
        XCTAssertGreaterThanOrEqual(count, 3, "Readiness requires fresh buffers after the route change")
        XCTAssertEqual(restartCount, 0)
    }

    func testStoppedBluetoothEngineRestartsAfterSettlingAndRequiresFreshAudio() async {
        var running = false
        var count: UInt64 = 100
        var restartCount = 0
        let ready = await AudioInputReadiness.wait(
            after: 0, generation: 0, requiredBuffers: 2,
            timeout: .seconds(1), pollInterval: .milliseconds(1), settlingInterval: .milliseconds(5),
            sample: {
                if running { count += 1 }
                return .init(generation: 1, bufferCount: count, isRunning: running, hasError: false)
            },
            restart: { restartCount += 1; running = true; return true }
        )
        XCTAssertTrue(ready)
        XCTAssertEqual(restartCount, 1)
        XCTAssertGreaterThanOrEqual(count, 103)
    }

    func testRouteThatNeverSuppliesAudioTimesOut() async {
        let ready = await AudioInputReadiness.wait(
            after: 0, generation: 0, requiredBuffers: 2,
            timeout: .milliseconds(10), pollInterval: .milliseconds(1),
            sample: { .init(generation: 0, bufferCount: 0, isRunning: true, hasError: false) },
            restart: { XCTFail("A running engine must not be restarted"); return false }
        )
        XCTAssertFalse(ready)
    }

    func testCancellationDuringSettlingCannotRestartMicrophone() async {
        var sampled = false
        var restartCount = 0
        let task = Task {
            await AudioInputReadiness.wait(
                after: 0, generation: 0, requiredBuffers: 2,
                timeout: .seconds(1), pollInterval: .milliseconds(1),
                sample: {
                    sampled = true
                    return .init(generation: 1, bufferCount: 0, isRunning: false, hasError: false)
                },
                restart: { restartCount += 1; return true }
            )
        }
        for _ in 0..<1_000 {
            if sampled { break }
            await Task.yield()
        }
        XCTAssertTrue(sampled)
        task.cancel()
        let ready = await task.value
        XCTAssertFalse(ready)
        XCTAssertEqual(restartCount, 0)
    }

    func testCaptureFailureStopsReadinessImmediately() async {
        let ready = await AudioInputReadiness.wait(
            after: 0, generation: 0, requiredBuffers: 2, timeout: .seconds(1),
            sample: { .init(generation: 0, bufferCount: 10, isRunning: true, hasError: true) },
            restart: { XCTFail("Failed capture must not restart"); return true }
        )
        XCTAssertFalse(ready)
    }
}
