import Darwin
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

    func testTimeoutIsNotDefeatedByPipeInheritingDescendant() async throws {
        let descendantPIDFile = fixtureDirectory.appendingPathComponent("descendant.pid")
        let executable = try makeExecutable(
            named: "inherited-pipe-timeout",
            body: """
            sleep 30 &
            descendant_pid=$!
            printf '%s' "$descendant_pid" > "$1"
            trap '' TERM
            while :; do :; done
            """
        )
        let start = Date()

        let result = await FoundationProcessRunner(terminationGracePeriod: 0.05).run(
            ProcessCommand(
                executableURL: executable,
                arguments: [descendantPIDFile.path]
            ),
            timeout: 1
        )

        let descendantPID = try readProcessIdentifier(from: descendantPIDFile)
        defer { _ = Darwin.kill(descendantPID, SIGKILL) }
        guard case .timedOut = result else {
            return XCTFail("Expected timeout, received \(result)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(Darwin.kill(descendantPID, 0), 0)
    }

    func testSynchronousTerminationWaitsForSIGTERMIgnoringProcessToExit() async throws {
        let processPIDFile = fixtureDirectory.appendingPathComponent("active.pid")
        let executable = try makeExecutable(
            named: "synchronous-termination",
            body: """
            trap '' TERM
            printf '%s' "$$" > "$1"
            while :; do :; done
            """
        )
        let runner = FoundationProcessRunner(terminationGracePeriod: 30)
        let task = Task {
            await runner.run(
                ProcessCommand(
                    executableURL: executable,
                    arguments: [processPIDFile.path]
                ),
                timeout: 30
            )
        }
        let processIdentifier = try await waitForProcessIdentifier(from: processPIDFile)

        runner.terminateActiveProcesses()

        XCTAssertEqual(Darwin.kill(processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
        guard case let .cancelled(diagnostic) = await task.value else {
            return XCTFail("Expected cancellation after synchronous termination")
        }
        XCTAssertEqual(diagnostic.terminationReason, .uncaughtSignal)
        XCTAssertEqual(diagnostic.terminationStatus, SIGKILL)
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

    private func waitForProcessIdentifier(from url: URL) async throws -> pid_t {
        for _ in 0..<200 {
            if let processIdentifier = try? readProcessIdentifier(from: url) {
                return processIdentifier
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private func readProcessIdentifier(from url: URL) throws -> pid_t {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let processIdentifier = pid_t(value) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return processIdentifier
    }
}
