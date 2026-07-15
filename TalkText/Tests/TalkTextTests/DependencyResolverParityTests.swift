import Foundation
import XCTest
@testable import TalkText

final class DependencyResolverParityTests: XCTestCase {
    private var fixtureDirectory: URL!

    override func setUpWithError() throws {
        let packageDirectory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TalkTextTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // TalkText package
        fixtureDirectory = packageDirectory
            .appendingPathComponent(".build", isDirectory: true)
            .appendingPathComponent("TalkText-ResolverParity-\(UUID().uuidString)", isDirectory: true)
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

    func testShellAndSwiftResolversSelectIdenticalPathsAndVersions() throws {
        for scenario in ResolverParityScenario.allCases {
            let fixture = try makeFixture(for: scenario)
            let shell = try shellObservation(for: fixture)
            let swift = try swiftObservation(for: fixture)

            XCTAssertEqual(
                shell.path,
                swift.path,
                "\(scenario.rawValue) selected different backend paths"
            )
            XCTAssertEqual(
                shell.version,
                swift.version,
                "\(scenario.rawValue) normalized different backend versions"
            )

            if let expected = fixture.expectedObservation {
                XCTAssertEqual(
                    shell.path,
                    expected.path,
                    "\(scenario.rawValue) shell selected an unexpected backend path"
                )
                XCTAssertEqual(
                    shell.version,
                    expected.version,
                    "\(scenario.rawValue) shell normalized an unexpected backend version"
                )
                XCTAssertEqual(
                    swift.path,
                    expected.path,
                    "\(scenario.rawValue) Swift selected an unexpected backend path"
                )
                XCTAssertEqual(
                    swift.version,
                    expected.version,
                    "\(scenario.rawValue) Swift normalized an unexpected backend version"
                )
            }
        }
    }

    private func makeFixture(for scenario: ResolverParityScenario) throws -> ResolverParityFixture {
        let root = fixtureDirectory.appendingPathComponent(scenario.rawValue, isDirectory: true)
        let workingDirectory = root.appendingPathComponent("working/project", isDirectory: true)
        let homeDirectory = root.appendingPathComponent("home", isDirectory: true)
        let emptyHomebrew = root.appendingPathComponent("empty-homebrew", isDirectory: true)
        let shellCheckout = root.appendingPathComponent("checkout", isDirectory: true)
        let shellScripts = shellCheckout.appendingPathComponent("scripts", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: emptyHomebrew, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shellScripts, withIntermediateDirectories: true)

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TalkTextTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // TalkText package
            .deletingLastPathComponent() // repository
        let shellTool = shellScripts.appendingPathComponent("dependency-tool.sh")
        let manifest = shellCheckout.appendingPathComponent("dependencies.env")
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("scripts/dependency-tool.sh"),
            to: shellTool
        )
        try FileManager.default.copyItem(
            at: repositoryRoot.appendingPathComponent("dependencies.env"),
            to: manifest
        )

        let model = root.appendingPathComponent("model.bin")
        var modelData = WhisperBackendContract.modelMagic
        modelData.append(Data(" resolver parity fixture".utf8))
        try modelData.write(to: model)

        var environment = [
            "HOME": homeDirectory.path,
            "HOMEBREW_PREFIX": emptyHomebrew.path,
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
            "TALKTEXT_BUNDLE_RESOURCES": "",
            "TALKTEXT_DEPENDENCY_MANIFEST": manifest.path,
            "TALKTEXT_DEVELOPMENT_ROOT": "",
            "TALKTEXT_MODEL_PATH": model.path,
            "TALKTEXT_WHISPER_CLI": "",
            "TALKTEXT_WHISPER_CLI_VERSION": "",
        ]
        var bundleResourceURL: URL?
        var expectedObservation: ResolverParityObservation?

        switch scenario {
        case .overrideDotDot:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("override/whisper-cli")
            )
            try writeSidecar(" \n v1.8.4 \t\n", for: backend)
            environment["TALKTEXT_WHISPER_CLI"] = "missing/../override/whisper-cli"
        case .bundle:
            let resources = root.appendingPathComponent("bundle-resources", isDirectory: true)
            let backend = try makeBackend(
                at: resources.appendingPathComponent("bin/whisper-cli")
            )
            try writeSidecar("1.9.1\n", for: backend)
            bundleResourceURL = resources
            environment["TALKTEXT_BUNDLE_RESOURCES"] = resources.path
        case .pathDotDot:
            _ = try makeBackend(
                at: workingDirectory.appendingPathComponent("toolchain/whisper-cli")
            )
            environment["PATH"] = "missing/../toolchain:/usr/bin:/bin"
        case .pathDot:
            _ = try makeBackend(
                at: workingDirectory.appendingPathComponent("tools/whisper-cli")
            )
            environment["PATH"] = "./tools:/usr/bin:/bin"
        case .pathLeadingEmpty:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("whisper-cli")
            )
            try writeSidecar("v1.8.4", for: backend)
            environment["PATH"] = ":/usr/bin:/bin"
        case .pathTrailingEmpty:
            _ = try makeBackend(
                at: workingDirectory.appendingPathComponent("whisper-cli")
            )
            environment["PATH"] = "/usr/bin:/bin:"
        case .pathOnlyEmpty:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("whisper-cli")
            )
            try writeSidecar("1.8.4", for: backend)
            environment["PATH"] = ""
        case .pathHomebrewSymlink:
            let prefix = root.appendingPathComponent("homebrew", isDirectory: true)
            let backend = try makeBackend(
                at: prefix.appendingPathComponent("Cellar/whisper-cpp/1.8.4/bin/whisper-cli")
            )
            try makeSymlink(
                at: prefix.appendingPathComponent("bin/whisper-cli"),
                destinationPath: "../Cellar/whisper-cpp/1.8.4/bin/whisper-cli"
            )
            environment["PATH"] = "\(prefix.appendingPathComponent("bin").path):/usr/bin:/bin"
            expectedObservation = ResolverParityObservation(path: backend.path, version: "1.8.4")
        case .symlinkedOverride:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("override-target/whisper-cli")
            )
            try writeSidecar(" \n v1.8.4 \t\n", for: backend)
            try makeSymlink(
                at: workingDirectory.appendingPathComponent("override-link/whisper-cli"),
                destinationPath: "../override-target/whisper-cli"
            )
            environment["TALKTEXT_WHISPER_CLI"] = "override-link/whisper-cli"
            expectedObservation = ResolverParityObservation(path: backend.path, version: "1.8.4")
        case .danglingVersionSidecar:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("dangling-sidecar/whisper-cli")
            )
            try makeSymlink(
                at: URL(fileURLWithPath: backend.path + ".version"),
                destinationPath: "missing-version"
            )
            environment["TALKTEXT_WHISPER_CLI"] = "dangling-sidecar/whisper-cli"
            expectedObservation = ResolverParityObservation(path: backend.path, version: nil)
        case .homebrewDotDot:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("homebrew/bin/whisper-cli")
            )
            try writeSidecar("1.8.4\n", for: backend)
            environment["HOMEBREW_PREFIX"] = "missing/../homebrew"
        case .developmentDotDot:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("configured/.dependencies/bin/whisper-cli")
            )
            try writeSidecar(" 1.9.1 \n", for: backend)
            environment["TALKTEXT_DEVELOPMENT_ROOT"] = "missing/../configured"
        case .malformedSidecar:
            let backend = try makeBackend(
                at: workingDirectory.appendingPathComponent("malformed/whisper-cli")
            )
            try writeSidecar("1.8. 4\n", for: backend)
            environment["TALKTEXT_WHISPER_CLI"] = "malformed/whisper-cli"
        case .missing:
            break
        }

        return ResolverParityFixture(
            environment: environment,
            bundleResourceURL: bundleResourceURL,
            executableURL: shellCheckout.appendingPathComponent("TalkText/.build/debug/TalkText"),
            currentDirectoryURL: workingDirectory,
            homeDirectoryURL: homeDirectory,
            shellToolURL: shellTool,
            expectedObservation: expectedObservation
        )
    }

    private func shellObservation(for fixture: ResolverParityFixture) throws -> ResolverParityObservation {
        let resolution = try runShell(
            fixture.shellToolURL,
            arguments: ["resolve-backend"],
            environment: fixture.environment,
            currentDirectoryURL: fixture.currentDirectoryURL
        )
        guard resolution.status == 0 else {
            guard resolution.output.contains("whisper-cli was not found") else {
                throw ResolverParityError.unexpectedShellOutput(resolution.output)
            }
            return ResolverParityObservation(path: nil, version: nil)
        }

        let path = resolution.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let probe = try runShell(
            fixture.shellToolURL,
            arguments: ["probe-backend", path],
            environment: fixture.environment,
            currentDirectoryURL: fixture.currentDirectoryURL
        )
        guard probe.status == 0 else {
            guard probe.output.contains("did not report a version") else {
                throw ResolverParityError.unexpectedShellOutput(probe.output)
            }
            return ResolverParityObservation(path: path, version: nil)
        }
        guard let versionLine = probe.output
            .split(separator: "\n")
            .first(where: { $0.hasPrefix("version=") }) else {
            throw ResolverParityError.unexpectedShellOutput(probe.output)
        }
        return ResolverParityObservation(
            path: path,
            version: String(versionLine.dropFirst("version=".count))
        )
    }

    private func swiftObservation(for fixture: ResolverParityFixture) throws -> ResolverParityObservation {
        let resolver = TalkTextDependencyResolver(
            configuration: DependencyResolverConfiguration(
                environment: fixture.environment,
                bundleResourceURL: fixture.bundleResourceURL,
                executableURL: fixture.executableURL,
                currentDirectoryURL: fixture.currentDirectoryURL,
                homeDirectoryURL: fixture.homeDirectoryURL,
                homebrewPrefixes: [],
                additionalDevelopmentRoots: [],
                modelFileName: WhisperBackendContract.modelFileName,
                expectedModelSizeBytes: nil
            ),
            probeRunner: FoundationDependencyProbeRunner()
        )

        switch resolver.preflight() {
        case let .ready(preflight):
            return ResolverParityObservation(
                path: preflight.backend.executable.url.path,
                version: preflight.backend.version
            )
        case .failure(.missingBinary):
            return ResolverParityObservation(path: nil, version: nil)
        case let .failure(.backendVersionUnreported(path)):
            return ResolverParityObservation(path: path, version: nil)
        case let .failure(failure):
            throw ResolverParityError.unexpectedSwiftFailure(failure)
        }
    }

    private func runShell(
        _ executableURL: URL,
        arguments: [String],
        environment: [String: String],
        currentDirectoryURL: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let decodedOutput = String(data: data, encoding: .utf8) else {
            throw ResolverParityError.invalidShellOutputEncoding
        }
        return (
            status: process.terminationStatus,
            output: decodedOutput
        )
    }

    @discardableResult
    private func makeBackend(at url: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let source = """
        #!/bin/bash
        set -euo pipefail
        case "${1:-}" in
            --help)
                printf '%s\\n' '--model --file --no-timestamps --threads'
                ;;
            --version)
                printf '%s\\n' 'fixture version 1.9.1'
                ;;
            *)
                exit 64
                ;;
        esac
        """
        try Data(source.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writeSidecar(_ value: String, for backend: URL) throws {
        try Data(value.utf8).write(to: URL(fileURLWithPath: backend.path + ".version"))
    }

    private func makeSymlink(at url: URL, destinationPath: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: url.path,
            withDestinationPath: destinationPath
        )
    }
}

private enum ResolverParityScenario: String, CaseIterable {
    case overrideDotDot = "override-dot-dot"
    case bundle
    case pathDotDot = "path-dot-dot"
    case pathDot = "path-dot"
    case pathLeadingEmpty = "path-leading-empty"
    case pathTrailingEmpty = "path-trailing-empty"
    case pathOnlyEmpty = "path-only-empty"
    case pathHomebrewSymlink = "path-homebrew-symlink"
    case symlinkedOverride = "symlinked-override"
    case danglingVersionSidecar = "dangling-version-sidecar"
    case homebrewDotDot = "homebrew-dot-dot"
    case developmentDotDot = "development-dot-dot"
    case malformedSidecar = "malformed-sidecar"
    case missing
}

private struct ResolverParityFixture {
    let environment: [String: String]
    let bundleResourceURL: URL?
    let executableURL: URL
    let currentDirectoryURL: URL
    let homeDirectoryURL: URL
    let shellToolURL: URL
    let expectedObservation: ResolverParityObservation?
}

private struct ResolverParityObservation: Equatable {
    let path: String?
    let version: String?
}

private enum ResolverParityError: Error {
    case invalidShellOutputEncoding
    case unexpectedShellOutput(String)
    case unexpectedSwiftFailure(TalkTextDependencyPreflightFailure)
}
