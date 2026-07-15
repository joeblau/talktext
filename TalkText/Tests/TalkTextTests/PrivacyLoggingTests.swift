import Foundation
import XCTest

final class PrivacyLoggingTests: XCTestCase {
    func testLoggingNeverInterpolatesRawTranscriptOrClipboardVariables() throws {
        let source = try productionSwiftSource()
        let rawUserContentInterpolation = #"\\\((?:text|transcript|transcription|cleaned|clipboardContents)(?!\.count)"#

        XCTAssertNil(
            source.range(of: rawUserContentInterpolation, options: .regularExpression),
            "Log-safe production code must not interpolate raw transcript/clipboard variables"
        )
        XCTAssertFalse(source.contains("Transcription: '"))
        XCTAssertFalse(source.contains("Attempting to insert transcription:"))
        XCTAssertFalse(source.contains("Inserted transcription:"))
    }

    func testLogsNeverRenderCapturedProcessOrClipboardBodies() throws {
        let loggerSources = try productionSourceFiles()
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .filter { $0.contains("Logger(") }
        let forbiddenLoggerInputs = [
            "standardOutputString",
            "standardErrorString",
            "launchErrorDescription",
            "clipboardContents",
        ]

        for source in loggerSources {
            for forbidden in forbiddenLoggerInputs {
                XCTAssertFalse(source.contains(forbidden), "Forbidden logging input: \(forbidden)")
            }
        }

        // Diagnostics retain bodies for typed handling, but logging is restricted
        // to byte counts, status/reason, and typed launch-error domain/code.
        let source = try productionSwiftSource()
        XCTAssertTrue(source.contains("standardOutput.count"))
        XCTAssertTrue(source.contains("standardError.count"))
    }

    func testLoggedResolvedPathsUsePrivateHashMask() throws {
        let engineSource = try source(named: "TranscriptionEngine.swift")
        let expression = try NSRegularExpression(pattern: #"\\\([^)]*\.url\.path[^)]*\)"#)
        let matches = expression.matches(
            in: engineSource,
            range: NSRange(engineSource.startIndex..., in: engineSource)
        )

        XCTAssertFalse(matches.isEmpty, "Expected typed dependency-path diagnostics")
        for match in matches {
            guard let range = Range(match.range, in: engineSource) else {
                return XCTFail("Could not inspect dependency-path interpolation")
            }
            let interpolation = String(engineSource[range])
            XCTAssertTrue(
                interpolation.contains(".private(mask: .hash)"),
                "Logged dependency paths must remain private and hash-masked"
            )
        }
    }

    private func productionSwiftSource() throws -> String {
        try productionSourceFiles()
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    private func productionSourceFiles() throws -> [URL] {
        let sourceDirectory = packageRoot()
            .appendingPathComponent("Sources/TalkText", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }
    }

    private func source(named name: String) throws -> String {
        try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/TalkText/\(name)"),
            encoding: .utf8
        )
    }

    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
