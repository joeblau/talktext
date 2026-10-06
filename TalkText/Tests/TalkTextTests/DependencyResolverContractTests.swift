import Foundation
import XCTest
@testable import TalkText

final class DependencyResolverContractTests: XCTestCase {
    private var root: URL!
    private var manifestURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TalkText-ParakeetResolver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        manifestURL = root.appendingPathComponent("manifest.json")
        let paths = ParakeetModelContract.requiredComponents.map { $0 + "/coremldata.bin" } + ["parakeet_vocab.json"]
        let manifest: [String: Any] = [
            "repository": "FluidInference/parakeet-tdt-0.6b-v2-coreml",
            "revision": String(repeating: "a", count: 40),
            "directory": ParakeetModelContract.directoryName,
            "fluidAudioVersion": ParakeetModelContract.sdkVersion,
            "files": paths.map { ["path": $0, "size": 3, "sha256": String(repeating: "b", count: 64)] as [String: Any] },
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testBundledModelIsPreferredWithoutAnExternalExecutable() throws {
        let bundled = try stageModels(under: root.appendingPathComponent("resources"))
        _ = try stageModels(under: root.appendingPathComponent("checkout"))
        let ready = try resolved(configuration(environment: ["TALKTEXT_DEVELOPMENT_ROOT": root.appendingPathComponent("checkout").path]))
        XCTAssertEqual(ready.model.url, bundled)
        XCTAssertEqual(ready.model.source, .bundled)
    }

    func testInvalidExplicitOverrideFailsBeforeBundledFallback() throws {
        _ = try stageModels(under: root.appendingPathComponent("resources"))
        let result = TalkTextDependencyResolver(configuration: configuration(environment: ["TALKTEXT_MODEL_PATH": "missing"])).preflight()
        guard case .failure(.invalidOverride) = result else { return XCTFail("Expected override failure") }
    }

    func testRelativeOverrideResolvesAgainstWorkingDirectory() throws {
        let model = try stageModels(under: root)
        let ready = try resolved(configuration(environment: ["TALKTEXT_MODEL_PATH": "models/" + ParakeetModelContract.directoryName]))
        XCTAssertEqual(ready.model.url, model)
        XCTAssertEqual(ready.model.source, .override)
    }

    func testSwiftPMExecutableFindsCheckoutModelsFromAnotherWorkingDirectory() throws {
        let checkout = root.appendingPathComponent("checkout")
        let model = try stageModels(under: checkout)
        var config = configuration()
        config.currentDirectoryURL = root.appendingPathComponent("elsewhere")
        config.executableURL = checkout.appendingPathComponent("TalkText/.build/arm64-apple-macosx/debug/TalkText")
        let ready = try resolved(config)
        XCTAssertEqual(ready.model.url, model)
        XCTAssertEqual(ready.model.source, .development)
    }

    func testIncompletePreferredBundleCannotFallBackToOtherWeights() throws {
        let bundle = try stageModels(under: root.appendingPathComponent("resources"))
        _ = try stageModels(under: root.appendingPathComponent("checkout"))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Encoder.mlmodelc/coremldata.bin"))
        let config = configuration(environment: ["TALKTEXT_DEVELOPMENT_ROOT": root.appendingPathComponent("checkout").path])
        guard case .failure(.invalidModel) = TalkTextDependencyResolver(configuration: config).preflight() else {
            return XCTFail("Expected the incomplete bundled model to fail")
        }
    }

    func testTruncatedModelAndUnreadableManifestAreRejected() throws {
        let model = try stageModels(under: root.appendingPathComponent("resources"))
        try Data().write(to: model.appendingPathComponent("Decoder.mlmodelc/coremldata.bin"))
        guard case .failure(.invalidModel) = TalkTextDependencyResolver(configuration: configuration()).preflight() else {
            return XCTFail("Expected a truncated model to fail")
        }
        try Data("invalid json".utf8).write(to: manifestURL)
        guard case .failure(.invalidModel) = TalkTextDependencyResolver(configuration: configuration()).preflight() else {
            return XCTFail("Expected an invalid manifest to fail")
        }
    }

    func testMissingModelsReportFailureInsteadOfDownloading() {
        guard case .failure(.missingModel) = TalkTextDependencyResolver(configuration: configuration()).preflight() else {
            return XCTFail("Expected missing local models")
        }
    }

    func testReviewedManifestPinsCompleteWeightsAndSDK() throws {
        let manifest = try JSONDecoder().decode(ParakeetModelManifest.self, from: Data(contentsOf: ParakeetModelContract.manifestURL))
        XCTAssertEqual(manifest.directory, ParakeetModelContract.directoryName)
        XCTAssertEqual(manifest.fluidAudioVersion, ParakeetModelContract.sdkVersion)
        XCTAssertNotNil(manifest.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression))
        for component in ParakeetModelContract.requiredComponents {
            XCTAssertTrue(manifest.files.contains { $0.path == component + "/coremldata.bin" })
        }
        XCTAssertTrue(manifest.files.contains { $0.path == "parakeet_vocab.json" })
        for file in manifest.files {
            XCTAssertGreaterThan(file.size, 0)
            XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resolved = try String(contentsOf: package.appendingPathComponent("Package.resolved"), encoding: .utf8)
        XCTAssertTrue(resolved.contains("\"version\" : \"0.17.4\""))
    }

    private func configuration(environment: [String: String] = [:]) -> ParakeetResolverConfiguration {
        ParakeetResolverConfiguration(
            environment: environment,
            bundleResourceURL: root.appendingPathComponent("resources"),
            executableURL: nil,
            currentDirectoryURL: root,
            applicationSupportURL: root.appendingPathComponent("support"),
            manifestURL: manifestURL
        )
    }

    private func resolved(_ config: ParakeetResolverConfiguration) throws -> TalkTextDependencyPreflight {
        switch TalkTextDependencyResolver(configuration: config).preflight() {
        case let .ready(value): value
        case let .failure(failure): throw failure
        }
    }

    private func stageModels(under parent: URL) throws -> URL {
        let model = parent.appendingPathComponent("models").appendingPathComponent(ParakeetModelContract.directoryName, isDirectory: true)
        let manifest = try JSONDecoder().decode(ParakeetModelManifest.self, from: Data(contentsOf: manifestURL))
        for file in manifest.files {
            let url = model.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("abc".utf8).write(to: url)
        }
        return model
    }
}
