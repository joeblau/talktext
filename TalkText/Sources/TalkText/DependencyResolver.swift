import Foundation

/// These weights and the SDK version are reviewed together. Setup and bundling
/// verify every file against the same manifest before the app loads local assets.
enum ParakeetModelContract {
    static let directoryName = "parakeet-tdt-0.6b-v2-coreml"
    static let sdkVersion = "0.17.4"
    static let requiredComponents = [
        "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecision.mlmodelc",
    ]

    static var manifestURL: URL {
        #if SWIFT_PACKAGE
            if Bundle.main.bundleURL.pathExtension != "app" {
                return (Bundle.module.resourceURL ?? Bundle.module.bundleURL).appendingPathComponent("parakeet-model.json")
            }
        #endif
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("parakeet-model.json")
    }
}

struct ParakeetModelManifest: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let path: String
        let size: UInt64
        let sha256: String
    }

    let repository: String
    let revision: String
    let directory: String
    let fluidAudioVersion: String
    let files: [File]
}

enum DependencySearchSource: String, Equatable, Sendable {
    case override
    case bundled
    case development
    case userData
}

struct ResolvedDependencyPath: Equatable, Sendable {
    let url: URL
    let source: DependencySearchSource
}

struct TalkTextDependencyPreflight: Equatable, Sendable {
    let model: ResolvedDependencyPath

    var diagnosticSummary: String {
        "Parakeet TDT 0.6B v2; FluidAudio=\(ParakeetModelContract.sdkVersion); model source=\(model.source.rawValue)"
    }
}

enum TalkTextDependencyPreflightFailure: Error, Equatable, Sendable {
    case invalidOverride(variable: String, path: String, requirement: String)
    case missingModel(searchedPaths: [String])
    case invalidModel(path: String, reason: String)
    case modelLoadFailed(TranscriptionDiagnostic)
    case unsupportedHardware

    var userMessage: String {
        switch self {
        case let .invalidOverride(variable, _, requirement):
            "\(variable) must point to \(requirement). Fix or unset it, then retry Parakeet setup."
        case .missingModel:
            "Parakeet models are missing. Run ./setup.sh from the TalkText checkout, or reinstall TalkText."
        case .invalidModel:
            "Parakeet models are incomplete or invalid. Run ./setup.sh from the TalkText checkout, or reinstall TalkText."
        case .modelLoadFailed:
            "Parakeet could not load its models. Retry setup, or reinstall TalkText."
        case .unsupportedHardware:
            "Parakeet requires Apple Silicon. On an Apple Silicon Mac, turn off Open using Rosetta and reopen TalkText."
        }
    }
}

enum TalkTextDependencyPreflightResult: Equatable, Sendable {
    case ready(TalkTextDependencyPreflight)
    case failure(TalkTextDependencyPreflightFailure)
}

struct ParakeetResolverConfiguration: Sendable {
    var environment: [String: String]
    var bundleResourceURL: URL?
    var executableURL: URL?
    var currentDirectoryURL: URL
    var applicationSupportURL: URL
    var manifestURL: URL

    static var production: Self {
        Self(
            environment: ProcessInfo.processInfo.environment,
            bundleResourceURL: Bundle.main.resourceURL,
            executableURL: Bundle.main.executableURL,
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            applicationSupportURL: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/TalkText", isDirectory: true),
            manifestURL: ParakeetModelContract.manifestURL
        )
    }
}

protocol ParakeetModelResolving: Sendable {
    func preflight() -> TalkTextDependencyPreflightResult
}

struct TalkTextDependencyResolver: ParakeetModelResolving {
    let configuration: ParakeetResolverConfiguration

    init(configuration: ParakeetResolverConfiguration = .production) {
        self.configuration = configuration
    }

    func preflight() -> TalkTextDependencyPreflightResult {
        let manifest: ParakeetModelManifest
        do {
            manifest = try JSONDecoder().decode(ParakeetModelManifest.self, from: Data(contentsOf: configuration.manifestURL))
        } catch {
            return .failure(.invalidModel(path: configuration.manifestURL.path, reason: "model manifest is unreadable"))
        }
        guard manifest.directory == ParakeetModelContract.directoryName,
              manifest.fluidAudioVersion == ParakeetModelContract.sdkVersion,
              !manifest.files.isEmpty else {
            return .failure(.invalidModel(path: configuration.manifestURL.path, reason: "model manifest does not match the backend"))
        }

        if let override = configuration.environment["TALKTEXT_MODEL_PATH"], !override.isEmpty {
            let url = resolveDirectory(override)
            if let reason = validationFailure(at: url, manifest: manifest) {
                return .failure(.invalidOverride(
                    variable: "TALKTEXT_MODEL_PATH",
                    path: url.path,
                    requirement: "a complete Parakeet v2 model directory (\(reason))"
                ))
            }
            return .ready(TalkTextDependencyPreflight(model: ResolvedDependencyPath(url: url, source: .override)))
        }

        let candidates = modelCandidates()
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.url.path) {
            // An invalid preferred bundle must never silently select different weights.
            if let reason = validationFailure(at: candidate.url, manifest: manifest) {
                return .failure(.invalidModel(path: candidate.url.path, reason: reason))
            }
            return .ready(TalkTextDependencyPreflight(model: candidate))
        }
        return .failure(.missingModel(searchedPaths: candidates.map { $0.url.path }))
    }

    private func resolveDirectory(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        return configuration.currentDirectoryURL.appendingPathComponent(path, isDirectory: true).standardizedFileURL
    }

    private func modelCandidates() -> [ResolvedDependencyPath] {
        var candidates: [ResolvedDependencyPath] = []
        func append(_ root: URL, source: DependencySearchSource) {
            let url = root.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(ParakeetModelContract.directoryName, isDirectory: true).standardizedFileURL
            if !candidates.contains(where: { $0.url == url }) {
                candidates.append(ResolvedDependencyPath(url: url, source: source))
            }
        }
        if let resourceURL = configuration.bundleResourceURL { append(resourceURL, source: .bundled) }
        if let root = configuration.environment["TALKTEXT_DEVELOPMENT_ROOT"], !root.isEmpty {
            append(resolveDirectory(root), source: .development)
        }
        if let executableURL = configuration.executableURL {
            var ancestor = executableURL.deletingLastPathComponent()
            while ancestor.path != "/" {
                if ancestor.lastPathComponent == ".build" {
                    append(ancestor.deletingLastPathComponent().deletingLastPathComponent(), source: .development)
                    break
                }
                ancestor.deleteLastPathComponent()
            }
        }
        append(configuration.currentDirectoryURL, source: .development)
        append(configuration.currentDirectoryURL.deletingLastPathComponent(), source: .development)
        append(configuration.applicationSupportURL, source: .userData)
        return candidates
    }

    private func validationFailure(at root: URL, manifest: ParakeetModelManifest) -> String? {
        let fileManager = FileManager.default
        guard let values = try? root.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else {
            return "directory is missing"
        }
        for entry in manifest.files {
            let file = root.appendingPathComponent(entry.path).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path + "/"),
                  let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  fileManager.isReadableFile(atPath: file.path),
                  values.fileSize.map({ UInt64($0) == entry.size }) == true else {
                return "a required file is missing, unreadable, or has the wrong size"
            }
        }
        return nil
    }
}
