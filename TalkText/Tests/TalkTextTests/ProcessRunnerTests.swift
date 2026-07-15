import Foundation
import XCTest
@testable import TalkText

final class ProcessRunnerTests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-ProcessRunnerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let fixtureDirectory {
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
    }

    func testDrainsLargeStandardOutputAndErrorWhileProcessRuns() async throws {
        let executable = try makeExecutable(
            named: "large-output",
            body: """
            dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\000' O
            dd if=/dev/zero bs=1024 count=2048 2>/dev/null | tr '\\000' E >&2
            """
        )

        let result = await FoundationProcessRunner().run(
            ProcessCommand(executableURL: executable),
            timeout: 10
        )

        guard case let .completed(diagnostic) = result else {
            return XCTFail("Expected completion, received \(result)")
        }
        XCTAssertTrue(diagnostic.exitedSuccessfully)
        XCTAssertEqual(diagnostic.standardOutput.count, 2 * 1024 * 1024)
        XCTAssertEqual(diagnostic.standardError.count, 2 * 1024 * 1024)
        XCTAssertEqual(diagnostic.standardOutput.first, Character("O").asciiValue)
        XCTAssertEqual(diagnostic.standardError.first, Character("E").asciiValue)
    }

    func testCapturesNonzeroExitAndStderr() async throws {
        let executable = try makeExecutable(
            named: "nonzero",
            body: """
            printf 'diagnostic on stderr' >&2
            exit 23
            """
        )

        let result = await FoundationProcessRunner().run(
            ProcessCommand(executableURL: executable),
            timeout: 2
        )

        guard case let .completed(diagnostic) = result else {
            return XCTFail("Expected completion, received \(result)")
        }
        XCTAssertFalse(diagnostic.exitedSuccessfully)
        XCTAssertEqual(diagnostic.terminationReason, .exit)
        XCTAssertEqual(diagnostic.terminationStatus, 23)
        XCTAssertEqual(diagnostic.standardErrorString, "diagnostic on stderr")
    }

    func testCapturesSignalTermination() async throws {
        let executable = try makeExecutable(
            named: "signal",
            body: "kill -TERM $$"
        )

        let result = await FoundationProcessRunner().run(
            ProcessCommand(executableURL: executable),
            timeout: 2
        )

        guard case let .completed(diagnostic) = result else {
            return XCTFail("Expected completion, received \(result)")
        }
        XCTAssertEqual(diagnostic.terminationReason, .uncaughtSignal)
        XCTAssertEqual(diagnostic.terminationStatus, SIGTERM)
    }

    func testTimeoutTerminatesProcessThatIgnoresSIGTERM() async throws {
        let executable = try makeExecutable(
            named: "timeout",
            body: """
            trap '' TERM
            while :; do :; done
            """
        )
        let start = Date()

        let result = await FoundationProcessRunner(terminationGracePeriod: 0.05).run(
            ProcessCommand(executableURL: executable),
            timeout: 0.05
        )

        guard case let .timedOut(diagnostic) = result else {
            return XCTFail("Expected timeout, received \(result)")
        }
        XCTAssertEqual(diagnostic.terminationReason, .uncaughtSignal)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testTaskCancellationTerminatesProcess() async throws {
        let executable = try makeExecutable(
            named: "cancel",
            body: """
            trap '' TERM
            while :; do :; done
            """
        )
        let runner = FoundationProcessRunner(terminationGracePeriod: 0.05)
        let task = Task {
            await runner.run(ProcessCommand(executableURL: executable), timeout: 30)
        }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()

        task.cancel()
        let result = await task.value

        guard case let .cancelled(diagnostic) = result else {
            return XCTFail("Expected cancellation, received \(result)")
        }
        XCTAssertEqual(diagnostic.terminationReason, .uncaughtSignal)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testLaunchFailurePreservesTypedNSErrorMetadata() async {
        let missingURL = fixtureDirectory.appendingPathComponent("does-not-exist")

        let result = await FoundationProcessRunner().run(
            ProcessCommand(executableURL: missingURL),
            timeout: 1
        )

        guard case let .launchFailed(diagnostic) = result else {
            return XCTFail("Expected launch failure, received \(result)")
        }
        XCTAssertNotNil(diagnostic.launchErrorDomain)
        XCTAssertNotNil(diagnostic.launchErrorCode)
        XCTAssertNotNil(diagnostic.launchErrorDescription)
        XCTAssertNil(diagnostic.terminationStatus)
    }

    private func makeExecutable(named name: String, body: String) throws -> URL {
        let url = fixtureDirectory.appendingPathComponent(name)
        let script = "#!/bin/sh\nset -eu\n\(body)\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        return url
    }
}
