import Foundation
import XCTest
@testable import TalkText

final class DependencyResolverContractTests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TalkText-DependencyResolverTests-\(UUID().uuidString)", isDirectory: true)
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

    func testBundledDependenciesTakePriorityAndPreflightCapturesVersion() throws {
        let resources = fixtureDirectory.appendingPathComponent("BundleResources", isDirectory: true)
        let backend = try makeExecutable(at: resources.appendingPathComponent("bin/whisper-cli"))
        let model = try makeModel(at: resources.appendingPathComponent("models/fixture-model.bin"))
        let resolver = makeResolver(
            environment: [
                "PATH": "",
                "TALKTEXT_WHISPER_CLI_VERSION": "1.8.4",
            ],
            bundleResourceURL: resources
        )

        let preflight = try readyPreflight(from: resolver)

        XCTAssertEqual(preflight.dependencies.binaryURL, backend.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.dependencies.modelURL, model.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.backend.executable.source, .bundled)
        XCTAssertEqual(preflight.model.source, .bundled)
        XCTAssertEqual(preflight.backend.version, "1.8.4")
        XCTAssertFalse(preflight.diagnosticSummary.contains(fixtureDirectory.path))
    }

    func testRelativePATHAndOverridesResolveAgainstInjectedWorkingDirectory() throws {
        let workingDirectory = fixtureDirectory.appendingPathComponent("working", isDirectory: true)
        let backend = try makeExecutable(at: workingDirectory.appendingPathComponent("toolchain/whisper-cli"))
        let model = try makeModel(at: workingDirectory.appendingPathComponent("relative/model.bin"))
        let resolver = makeResolver(
            environment: [
                "PATH": "toolchain",
                "TALKTEXT_MODEL_PATH": "relative/model.bin",
                "TALKTEXT_WHISPER_CLI_VERSION": "1.9.1",
            ],
            currentDirectoryURL: workingDirectory
        )

        let preflight = try readyPreflight(from: resolver)

        XCTAssertEqual(preflight.dependencies.binaryURL, backend.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.dependencies.modelURL, model.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.backend.executable.source, .path)
        XCTAssertEqual(preflight.model.source, .override)
    }

    func testExplicitOverridesWinOverBundledDependencies() throws {
        let resources = fixtureDirectory.appendingPathComponent("resources", isDirectory: true)
        _ = try makeExecutable(at: resources.appendingPathComponent("bin/whisper-cli"))
        _ = try makeModel(at: resources.appendingPathComponent("models/fixture-model.bin"))
        let overrideBackend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("overrides/backend"))
        let overrideModel = try makeModel(at: fixtureDirectory.appendingPathComponent("overrides/model.bin"))
        let resolver = makeResolver(
            environment: [
                "PATH": "",
                "TALKTEXT_WHISPER_CLI": overrideBackend.path,
                "TALKTEXT_MODEL_PATH": overrideModel.path,
                "TALKTEXT_WHISPER_CLI_VERSION": "1.9.1",
            ],
            bundleResourceURL: resources
        )

        let preflight = try readyPreflight(from: resolver)

        XCTAssertEqual(preflight.backend.executable.source, .override)
        XCTAssertEqual(preflight.model.source, .override)
        XCTAssertEqual(preflight.dependencies.binaryURL, overrideBackend.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.dependencies.modelURL, overrideModel.resolvingSymlinksInPath())
    }

    func testHomebrewPrefixDiscovery() throws {
        let prefix = fixtureDirectory.appendingPathComponent("homebrew", isDirectory: true)
        let backend = try makeExecutable(at: prefix.appendingPathComponent("bin/whisper-cli"))
        let model = try makeModel(at: fixtureDirectory.appendingPathComponent("model.bin"))
        let resolver = makeResolver(
            environment: [
                "PATH": "",
                "HOMEBREW_PREFIX": prefix.path,
                "TALKTEXT_MODEL_PATH": model.path,
                "TALKTEXT_WHISPER_CLI_VERSION": "1.8.4",
            ]
        )

        let preflight = try readyPreflight(from: resolver)

        XCTAssertEqual(preflight.dependencies.binaryURL, backend.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.backend.executable.source, .homebrew)
    }

    func testDevelopmentModelAndBackendAreInferredFromSwiftPMExecutable() throws {
        let repository = fixtureDirectory.appendingPathComponent("checkout", isDirectory: true)
        let package = repository.appendingPathComponent("TalkText", isDirectory: true)
        let executable = package.appendingPathComponent(".build/release/TalkText")
        let backend = try makeExecutable(at: repository.appendingPathComponent(".dependencies/bin/whisper-cli"))
        let model = try makeModel(at: repository.appendingPathComponent("models/fixture-model.bin"))
        let unrelatedWorkingDirectory = fixtureDirectory.appendingPathComponent("somewhere/else", isDirectory: true)
        let resolver = makeResolver(
            environment: [
                "PATH": "",
                "TALKTEXT_WHISPER_CLI_VERSION": "1.8.4",
            ],
            executableURL: executable,
            currentDirectoryURL: unrelatedWorkingDirectory
        )

        let preflight = try readyPreflight(from: resolver)

        XCTAssertEqual(preflight.dependencies.binaryURL, backend.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.dependencies.modelURL, model.resolvingSymlinksInPath())
        XCTAssertEqual(preflight.backend.executable.source, .development)
        XCTAssertEqual(preflight.model.source, .development)
    }

    func testMissingBinaryReportsActionableFailure() {
        let resolver = makeResolver(environment: ["PATH": ""])

        guard case let .failure(.missingBinary(paths)) = resolver.preflight() else {
            return XCTFail("Expected a missing binary failure")
        }
        XCTAssertFalse(paths.isEmpty)
    }

    func testMissingModelReportsActionableFailure() throws {
        let backend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("bin/whisper-cli"))
        let resolver = makeResolver(environment: [
            "PATH": "",
            "TALKTEXT_WHISPER_CLI": backend.path,
            "TALKTEXT_WHISPER_CLI_VERSION": "1.8.4",
        ])

        guard case let .failure(failure) = resolver.preflight() else {
            return XCTFail("Expected a missing model failure")
        }
        guard case .missingModel = failure else {
            return XCTFail("Expected missingModel, received \(failure)")
        }
        XCTAssertTrue(failure.userMessage.contains("./setup.sh"))
    }

    func testInvalidExplicitOverrideFailsClosed() throws {
        let validBackend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("path/whisper-cli"))
        let invalidOverride = fixtureDirectory.appendingPathComponent("not-an-executable", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidOverride, withIntermediateDirectories: true)
        let resolver = makeResolver(environment: [
            "PATH": validBackend.deletingLastPathComponent().path,
            "TALKTEXT_WHISPER_CLI": invalidOverride.path,
            "TALKTEXT_WHISPER_CLI_VERSION": "1.8.4",
        ])

        guard case let .failure(.invalidOverride(variable, _, _)) = resolver.preflight() else {
            return XCTFail("Expected invalid override to fail closed")
        }
        XCTAssertEqual(variable, "TALKTEXT_WHISPER_CLI")
    }

    func testInvalidModelHeaderIsRejectedBeforeRecording() throws {
        let backend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("bin/whisper-cli"))
        let model = fixtureDirectory.appendingPathComponent("bad-model.bin")
        try Data("not-ggml".utf8).write(to: model)
        let resolver = makeResolver(environment: [
            "PATH": "",
            "TALKTEXT_WHISPER_CLI": backend.path,
            "TALKTEXT_MODEL_PATH": model.path,
            "TALKTEXT_WHISPER_CLI_VERSION": "1.8.4",
        ])

        guard case let .failure(.invalidModel(path, reason)) = resolver.preflight() else {
            return XCTFail("Expected an invalid model failure")
        }
        XCTAssertEqual(path, model.path)
        XCTAssertTrue(reason.contains("GGML"))
    }

    func testUnsupportedBackendVersionFailsClosed() throws {
        let backend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("bin/whisper-cli"))
        let model = try makeModel(at: fixtureDirectory.appendingPathComponent("model.bin"))
        let resolver = makeResolver(environment: [
            "PATH": "",
            "TALKTEXT_WHISPER_CLI": backend.path,
            "TALKTEXT_MODEL_PATH": model.path,
            "TALKTEXT_WHISPER_CLI_VERSION": "2.0.0",
        ])

        guard case let .failure(.unsupportedBackendVersion(_, version, supported)) = resolver.preflight() else {
            return XCTFail("Expected unsupported backend version failure")
        }
        XCTAssertEqual(version, "2.0.0")
        XCTAssertEqual(supported, ["1.8.4", "1.9.1"])
    }

    func testMissingProductionOptionFailsClosed() throws {
        let backend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("bin/whisper-cli"))
        let model = try makeModel(at: fixtureDirectory.appendingPathComponent("model.bin"))
        let runner = StubDependencyProbeRunner(
            help: DependencyProbeOutput(
                terminationStatus: 0,
                output: "--model --file --no-timestamps"
            ),
            version: nil
        )
        let resolver = makeResolver(
            environment: [
                "PATH": "",
                "TALKTEXT_WHISPER_CLI": backend.path,
                "TALKTEXT_MODEL_PATH": model.path,
                "TALKTEXT_WHISPER_CLI_VERSION": "1.8.4",
            ],
            runner: runner
        )

        guard case let .failure(.backendMissingOptions(_, options)) = resolver.preflight() else {
            return XCTFail("Expected missing backend option failure")
        }
        XCTAssertEqual(options, ["--threads"])
    }

    func testUnreportedVersionFailsClosed() throws {
        let backend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("custom/whisper-cli"))
        let model = try makeModel(at: fixtureDirectory.appendingPathComponent("model.bin"))
        let runner = StubDependencyProbeRunner.compatible(versionOutput: "usage only")
        let resolver = makeResolver(
            environment: [
                "PATH": "",
                "TALKTEXT_WHISPER_CLI": backend.path,
                "TALKTEXT_MODEL_PATH": model.path,
            ],
            runner: runner
        )

        guard case .failure(.backendVersionUnreported) = resolver.preflight() else {
            return XCTFail("Expected unreported version failure")
        }
    }

    func testVersionSidecarSupportsPinnedBundledBackend() throws {
        let backend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("bundle/bin/whisper-cli"))
        try Data("1.9.1\n".utf8).write(to: URL(fileURLWithPath: backend.path + ".version"))
        let model = try makeModel(at: fixtureDirectory.appendingPathComponent("model.bin"))
        let resolver = makeResolver(environment: [
            "PATH": "",
            "TALKTEXT_WHISPER_CLI": backend.path,
            "TALKTEXT_MODEL_PATH": model.path,
        ])

        XCTAssertEqual(try readyPreflight(from: resolver).backend.version, "1.9.1")
    }

    func testMalformedVersionSidecarFailsClosed() throws {
        let backend = try makeExecutable(at: fixtureDirectory.appendingPathComponent("bundle/bin/whisper-cli"))
        try Data("1.8. 4\n".utf8).write(to: URL(fileURLWithPath: backend.path + ".version"))
        let model = try makeModel(at: fixtureDirectory.appendingPathComponent("model.bin"))
        let resolver = makeResolver(
            environment: [
                "PATH": "",
                "TALKTEXT_WHISPER_CLI": backend.path,
                "TALKTEXT_MODEL_PATH": model.path,
            ],
            runner: StubDependencyProbeRunner.compatible(versionOutput: "whisper.cpp version 1.9.1")
        )

        guard case .failure(.backendVersionUnreported) = resolver.preflight() else {
            return XCTFail("Expected malformed sidecar metadata to fail closed")
        }
    }

    func testProductionInvocationArgumentsAreExact() {
        let arguments = WhisperBackendContract.productionArguments(
            modelURL: URL(fileURLWithPath: "/model.ggml"),
            audioURL: URL(fileURLWithPath: "/controlled.wav")
        )

        XCTAssertEqual(arguments, [
            "--model", "/model.ggml",
            "--file", "/controlled.wav",
            "--no-timestamps",
            "--threads", "4",
        ])
    }

    func testCompiledContractMatchesReviewedManifest() throws {
        let manifestURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TalkTextTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // TalkText package
            .deletingLastPathComponent() // repository
            .appendingPathComponent("dependencies.env")
        let manifest = try parseManifest(at: manifestURL)

        XCTAssertEqual(manifest["BACKEND_EXECUTABLE"], WhisperBackendContract.executableName)
        XCTAssertEqual(manifest["BACKEND_FORMULA"], WhisperBackendContract.formulaName)
        XCTAssertEqual(manifest["MODEL_FILE_NAME"], WhisperBackendContract.modelFileName)
        XCTAssertEqual(try UInt64(XCTUnwrap(manifest["MODEL_SIZE_BYTES"])), WhisperBackendContract.modelSizeBytes)
        XCTAssertEqual(
            try data(fromHexadecimal: XCTUnwrap(manifest["MODEL_MAGIC_HEX"])),
            WhisperBackendContract.modelMagic
        )
        XCTAssertEqual(
            manifest["BACKEND_SUPPORTED_VERSIONS"]?.split(separator: " ").map(String.init),
            WhisperBackendContract.supportedVersions
        )
        XCTAssertEqual(
            manifest["BACKEND_REQUIRED_FLAGS"]?.split(separator: " ").map(String.init),
            WhisperBackendContract.requiredOptions
        )
    }

    func testFoundationProbeBoundsVerboseOutputWithoutDeadlocking() throws {
        let executable = try makeExecutable(
            at: fixtureDirectory.appendingPathComponent("verbose"),
            body: "dd if=/dev/zero bs=1024 count=512 2>/dev/null | tr '\\000' X"
        )
        let runner = FoundationDependencyProbeRunner(
            timeout: 2,
            maximumOutputBytes: 4_096
        )

        let result = try XCTUnwrap(runner.run(executableURL: executable, arguments: []))

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertLessThanOrEqual(result.output.utf8.count, 4_096)
    }

    func testFoundationProbeTimesOutStuckBackend() throws {
        let executable = try makeExecutable(
            at: fixtureDirectory.appendingPathComponent("stuck"),
            body: "exec /bin/sleep 5"
        )
        let runner = FoundationDependencyProbeRunner(
            timeout: 0.05,
            terminationGracePeriod: 0.05
        )
        let start = Date()

        let result = runner.run(executableURL: executable, arguments: [])

        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    private func makeResolver(
        environment: [String: String],
        bundleResourceURL: URL? = nil,
        executableURL: URL? = nil,
        currentDirectoryURL: URL? = nil,
        runner: any DependencyProbeRunning = StubDependencyProbeRunner.compatible()
    ) -> TalkTextDependencyResolver {
        TalkTextDependencyResolver(
            configuration: DependencyResolverConfiguration(
                environment: environment,
                bundleResourceURL: bundleResourceURL,
                executableURL: executableURL,
                currentDirectoryURL: currentDirectoryURL ?? fixtureDirectory,
                homeDirectoryURL: fixtureDirectory.appendingPathComponent("home", isDirectory: true),
                homebrewPrefixes: [],
                additionalDevelopmentRoots: [],
                modelFileName: "fixture-model.bin",
                expectedModelSizeBytes: nil
            ),
            probeRunner: runner
        )
    }

    private func readyPreflight(
        from resolver: TalkTextDependencyResolver
    ) throws -> TalkTextDependencyPreflight {
        switch resolver.preflight() {
        case let .ready(preflight):
            return preflight
        case let .failure(failure):
            throw failure
        }
    }

    @discardableResult
    private func makeExecutable(at url: URL, body: String = "exit 0") throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/bash\nset -euo pipefail\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    private func makeModel(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var data = WhisperBackendContract.modelMagic
        data.append(Data(" deterministic fixture".utf8))
        try data.write(to: url)
        return url
    }

    private func parseManifest(at url: URL) throws -> [String: String] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return contents.split(separator: "\n").reduce(into: [:]) { values, line in
            guard !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=") else {
                return
            }
            let key = String(line[..<separator])
            var value = String(line[line.index(after: separator)...])
            if value.hasPrefix("'"), value.hasSuffix("'") {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
    }

    private func data(fromHexadecimal value: String) throws -> Data {
        guard value.count.isMultiple(of: 2) else {
            throw HexadecimalFixtureError.invalidValue(value)
        }
        return try stride(from: 0, to: value.count, by: 2).reduce(into: Data()) { data, offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: 2)
            guard let byte = UInt8(value[start ..< end], radix: 16) else {
                throw HexadecimalFixtureError.invalidValue(value)
            }
            data.append(byte)
        }
    }
}

private enum HexadecimalFixtureError: Error {
    case invalidValue(String)
}

private struct StubDependencyProbeRunner: DependencyProbeRunning {
    let help: DependencyProbeOutput?
    let version: DependencyProbeOutput?

    static func compatible(versionOutput: String = "whisper.cpp version 1.8.4") -> StubDependencyProbeRunner {
        StubDependencyProbeRunner(
            help: DependencyProbeOutput(
                terminationStatus: 0,
                output: WhisperBackendContract.requiredOptions.joined(separator: " ")
            ),
            version: DependencyProbeOutput(terminationStatus: 0, output: versionOutput)
        )
    }

    func run(executableURL: URL, arguments: [String]) -> DependencyProbeOutput? {
        arguments == ["--help"] ? help : version
    }
}
