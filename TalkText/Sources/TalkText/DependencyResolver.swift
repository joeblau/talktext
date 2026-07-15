import Darwin
import Foundation

/// The reviewed runtime contract mirrored by `dependencies.env`.
/// `DependencyResolverContractTests` prevents these compiled values from
/// drifting from the manifest used by setup, bundling, and CI.
enum WhisperBackendContract {
    static let executableName = "whisper-cli"
    static let formulaName = "whisper-cpp"
    static let modelFileName = "ggml-base.en.bin"
    static let modelSizeBytes: UInt64 = 147_964_211
    static let modelMagic = Data([0x6c, 0x6d, 0x67, 0x67])
    static let supportedVersions = ["1.8.4", "1.9.1"]
    static let requiredOptions = ["--model", "--file", "--no-timestamps", "--threads"]

    static func productionArguments(
        modelURL: URL,
        audioURL: URL,
        threadCount: Int = 4
    ) -> [String] {
        [
            "--model", modelURL.path,
            "--file", audioURL.path,
            "--no-timestamps",
            "--threads", String(max(1, threadCount)),
        ]
    }
}

enum DependencySearchSource: String, Equatable, Sendable {
    case override
    case bundled
    case path
    case homebrew
    case development
    case userData
}

struct ResolvedDependencyPath: Equatable, Sendable {
    let url: URL
    let source: DependencySearchSource
}

struct WhisperBackendDiagnostic: Equatable, Sendable {
    let executable: ResolvedDependencyPath
    let version: String
    let compatibility: String
}

struct TalkTextDependencyPreflight: Equatable, Sendable {
    let dependencies: ResolvedWhisperDependencies
    let backend: WhisperBackendDiagnostic
    let model: ResolvedDependencyPath

    /// Safe for public startup logs. Resolved URLs remain available as typed
    /// fields so callers can capture them with private OSLog interpolation.
    /// This summary never includes a user-derived path or dictated content.
    var diagnosticSummary: String {
        let backendSource = backend.executable.source.rawValue
        let modelSource = model.source.rawValue
        return "whisper-cli source=\(backendSource) version=\(backend.version) "
            + "compatibility=\(backend.compatibility); model source=\(modelSource)"
    }
}

enum TalkTextDependencyPreflightFailure: Error, Equatable, Sendable {
    case invalidOverride(variable: String, path: String, requirement: String)
    case missingBinary(searchedPaths: [String])
    case missingModel(searchedPaths: [String])
    case invalidModel(path: String, reason: String)
    case backendProbeFailed(path: String)
    case backendMissingOptions(path: String, options: [String])
    case backendVersionUnreported(path: String)
    case unsupportedBackendVersion(path: String, version: String, supported: [String])

    var userMessage: String {
        switch self {
        case let .invalidOverride(variable, path, requirement):
            "\(variable) points to \(path), which is not \(requirement). Fix or unset \(variable)."
        case .missingBinary:
            "whisper-cli was not found. Run ./setup.sh or set TALKTEXT_WHISPER_CLI to a supported executable."
        case .missingModel:
            "The verified base.en model was not found. Run ./setup.sh or set TALKTEXT_MODEL_PATH."
        case let .invalidModel(path, reason):
            "The Whisper model at \(path) is invalid (\(reason)). Run ./setup.sh to verify or replace it."
        case let .backendProbeFailed(path):
            "whisper-cli at \(path) could not report its supported options. Reinstall whisper-cpp or select another backend."
        case let .backendMissingOptions(path, options):
            "whisper-cli at \(path) is incompatible; it is missing: \(options.joined(separator: ", "))."
        case let .backendVersionUnreported(path):
            "whisper-cli at \(path) did not report a version. Install the supported Homebrew formula, add a .version sidecar, or set TALKTEXT_WHISPER_CLI_VERSION after verifying the build."
        case let .unsupportedBackendVersion(_, version, supported):
            "whisper-cli \(version) is unsupported. Install one of: \(supported.joined(separator: ", "))."
        }
    }
}

enum TalkTextDependencyPreflightResult: Equatable, Sendable {
    case ready(TalkTextDependencyPreflight)
    case failure(TalkTextDependencyPreflightFailure)
}

struct DependencyResolverConfiguration: Equatable, Sendable {
    var environment: [String: String]
    var bundleResourceURL: URL?
    var executableURL: URL?
    var currentDirectoryURL: URL
    var homeDirectoryURL: URL
    var homebrewPrefixes: [URL]
    var additionalDevelopmentRoots: [URL]
    var modelFileName: String
    var expectedModelSizeBytes: UInt64?

    static var production: DependencyResolverConfiguration {
        DependencyResolverConfiguration(
            environment: ProcessInfo.processInfo.environment,
            bundleResourceURL: Bundle.main.resourceURL,
            executableURL: Bundle.main.executableURL,
            currentDirectoryURL: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser,
            homebrewPrefixes: [
                URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
                URL(fileURLWithPath: "/usr/local", isDirectory: true),
            ],
            additionalDevelopmentRoots: [],
            modelFileName: WhisperBackendContract.modelFileName,
            expectedModelSizeBytes: WhisperBackendContract.modelSizeBytes
        )
    }
}

struct DependencyProbeOutput: Equatable, Sendable {
    let terminationStatus: Int32
    let output: String
}

protocol DependencyProbeRunning: Sendable {
    func run(executableURL: URL, arguments: [String]) -> DependencyProbeOutput?
}

struct FoundationDependencyProbeRunner: DependencyProbeRunning {
    private let timeout: TimeInterval
    private let terminationGracePeriod: TimeInterval
    private let maximumOutputBytes: Int

    init(
        timeout: TimeInterval = 5,
        terminationGracePeriod: TimeInterval = 0.25,
        maximumOutputBytes: Int = 64 * 1_024
    ) {
        self.timeout = max(0.01, timeout)
        self.terminationGracePeriod = max(0.01, terminationGracePeriod)
        self.maximumOutputBytes = max(1_024, maximumOutputBytes)
    }

    func run(executableURL: URL, arguments: [String]) -> DependencyProbeOutput? {
        let process = Process()
        let standardOutput = Pipe()
        let standardError = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = standardOutput
        process.standardError = standardError

        do {
            try process.run()
        } catch {
            return nil
        }

        // Start readers immediately after launch. A child that fills either
        // pipe briefly blocks until its reader starts, then both streams are
        // drained concurrently for the rest of the probe.
        let outputCapture = DependencyProbeCapture(limit: maximumOutputBytes)
        let errorCapture = DependencyProbeCapture(limit: maximumOutputBytes)
        let drainGroup = DispatchGroup()
        drain(standardOutput.fileHandleForReading, into: outputCapture, group: drainGroup)
        drain(standardError.fileHandleForReading, into: errorCapture, group: drainGroup)

        let processBox = DependencyProbeProcess(process)
        let termination = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            processBox.process.waitUntilExit()
            termination.signal()
        }

        if termination.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if termination.wait(timeout: .now() + terminationGracePeriod) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = termination.wait(timeout: .now() + terminationGracePeriod)
            }
            try? standardOutput.fileHandleForReading.close()
            try? standardError.fileHandleForReading.close()
            return nil
        }

        _ = drainGroup.wait(timeout: .now() + terminationGracePeriod)
        guard let output = String(
            data: outputCapture.data + errorCapture.data,
            encoding: .utf8
        ) else {
            return nil
        }
        return DependencyProbeOutput(
            terminationStatus: process.terminationStatus,
            output: output
        )
    }

    private func drain(
        _ handle: FileHandle,
        into capture: DependencyProbeCapture,
        group: DispatchGroup
    ) {
        let handleBox = DependencyProbeFileHandle(handle)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = handleBox.handle.availableData
                guard !data.isEmpty else { break }
                capture.append(data)
            }
            group.leave()
        }
    }
}

private final class DependencyProbeProcess: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class DependencyProbeFileHandle: @unchecked Sendable {
    let handle: FileHandle

    init(_ handle: FileHandle) {
        self.handle = handle
    }
}

private final class DependencyProbeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()

    init(limit: Int) {
        self.limit = limit
    }

    var data: Data {
        lock.withLock { storage }
    }

    func append(_ data: Data) {
        lock.withLock {
            let remaining = limit - storage.count
            guard remaining > 0 else { return }
            storage.append(data.prefix(remaining))
        }
    }
}

/// Canonical dependency resolver used by startup diagnostics and transcription.
/// Resolution order is override, bundled resource, PATH, Homebrew, development,
/// then user data. Invalid explicit overrides fail closed instead of silently
/// falling back to a different dependency.
struct TalkTextDependencyResolver: WhisperDependencyResolving {
    private let configuration: DependencyResolverConfiguration
    private let probeRunner: any DependencyProbeRunning

    init(
        configuration: DependencyResolverConfiguration = .production,
        probeRunner: any DependencyProbeRunning = FoundationDependencyProbeRunner()
    ) {
        self.configuration = configuration
        self.probeRunner = probeRunner
    }

    static var production: TalkTextDependencyResolver {
        TalkTextDependencyResolver()
    }

    func resolveDependencies() -> WhisperDependencyResolution {
        switch preflight() {
        case let .ready(preflight):
            return .resolved(preflight.dependencies)
        case let .failure(failure):
            return .missing(failure.missingDependency)
        }
    }

    func preflight() -> TalkTextDependencyPreflightResult {
        let backendResolution = resolveBackendPath()
        let backendPath: ResolvedDependencyPath
        switch backendResolution {
        case let .success(path):
            backendPath = path
        case let .failure(failure):
            return .failure(failure)
        }

        let modelResolution = resolveModelPath()
        let modelPath: ResolvedDependencyPath
        switch modelResolution {
        case let .success(path):
            modelPath = path
        case let .failure(failure):
            return .failure(failure)
        }

        if let failure = validateModel(at: modelPath.url) {
            return .failure(failure)
        }

        let backendDiagnostic: WhisperBackendDiagnostic
        switch probeBackend(at: backendPath) {
        case let .success(diagnostic):
            backendDiagnostic = diagnostic
        case let .failure(failure):
            return .failure(failure)
        }

        let dependencies = ResolvedWhisperDependencies(
            binaryURL: backendPath.url,
            modelURL: modelPath.url
        )
        return .ready(TalkTextDependencyPreflight(
            dependencies: dependencies,
            backend: backendDiagnostic,
            model: modelPath
        ))
    }

    private func resolveBackendPath() -> Result<ResolvedDependencyPath, TalkTextDependencyPreflightFailure> {
        if let override = nonemptyEnvironmentValue("TALKTEXT_WHISPER_CLI") {
            let url = configuredURL(for: override)
            guard isReadableRegularFile(url), FileManager.default.isExecutableFile(atPath: url.path) else {
                return .failure(.invalidOverride(
                    variable: "TALKTEXT_WHISPER_CLI",
                    path: url.path,
                    requirement: "a readable executable file"
                ))
            }
            return .success(ResolvedDependencyPath(url: canonical(url), source: .override))
        }

        var candidates: [(URL, DependencySearchSource)] = []
        if let resourceURL = configuration.bundleResourceURL {
            candidates.append((resourceURL.appendingPathComponent("bin/\(WhisperBackendContract.executableName)"), .bundled))
            candidates.append((resourceURL.appendingPathComponent(WhisperBackendContract.executableName), .bundled))
        }

        for pathEntry in pathEntries() {
            candidates.append((pathEntry.appendingPathComponent(WhisperBackendContract.executableName), .path))
        }

        for prefix in homebrewPrefixes() {
            candidates.append((prefix.appendingPathComponent("bin/\(WhisperBackendContract.executableName)"), .homebrew))
        }

        for root in developmentRoots() {
            candidates.append((root.appendingPathComponent(".dependencies/bin/\(WhisperBackendContract.executableName)"), .development))
            candidates.append((root.appendingPathComponent("bin/\(WhisperBackendContract.executableName)"), .development))
        }

        candidates.append((
            configuration.homeDirectoryURL.appendingPathComponent(".local/bin/\(WhisperBackendContract.executableName)"),
            .userData
        ))

        let uniqueCandidates = deduplicated(candidates)
        if let match = uniqueCandidates.first(where: {
            isReadableRegularFile($0.0) && FileManager.default.isExecutableFile(atPath: $0.0.path)
        }) {
            return .success(ResolvedDependencyPath(url: canonical(match.0), source: match.1))
        }
        return .failure(.missingBinary(searchedPaths: uniqueCandidates.map(\.0.path)))
    }

    private func resolveModelPath() -> Result<ResolvedDependencyPath, TalkTextDependencyPreflightFailure> {
        if let override = nonemptyEnvironmentValue("TALKTEXT_MODEL_PATH") {
            let url = configuredURL(for: override)
            guard isReadableRegularFile(url) else {
                return .failure(.invalidOverride(
                    variable: "TALKTEXT_MODEL_PATH",
                    path: url.path,
                    requirement: "a readable regular file"
                ))
            }
            return .success(ResolvedDependencyPath(url: canonical(url), source: .override))
        }

        var candidates: [(URL, DependencySearchSource)] = []
        if let resourceURL = configuration.bundleResourceURL {
            candidates.append((resourceURL.appendingPathComponent("models/\(configuration.modelFileName)"), .bundled))
        }
        for root in developmentRoots() {
            candidates.append((root.appendingPathComponent("models/\(configuration.modelFileName)"), .development))
        }
        candidates.append((
            configuration.homeDirectoryURL
                .appendingPathComponent("Library/Application Support/TalkText/models/\(configuration.modelFileName)"),
            .userData
        ))
        candidates.append((
            configuration.homeDirectoryURL.appendingPathComponent(".local/share/talktext/models/\(configuration.modelFileName)"),
            .userData
        ))
        candidates.append((
            configuration.homeDirectoryURL.appendingPathComponent(".local/share/whisper/\(configuration.modelFileName)"),
            .userData
        ))
        for prefix in homebrewPrefixes() {
            candidates.append((prefix.appendingPathComponent("share/whisper/models/\(configuration.modelFileName)"), .homebrew))
        }

        let uniqueCandidates = deduplicated(candidates)
        if let match = uniqueCandidates.first(where: { isReadableRegularFile($0.0) }) {
            return .success(ResolvedDependencyPath(url: canonical(match.0), source: match.1))
        }
        return .failure(.missingModel(searchedPaths: uniqueCandidates.map(\.0.path)))
    }

    private func validateModel(at url: URL) -> TalkTextDependencyPreflightFailure? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return .invalidModel(path: url.path, reason: "size is unreadable")
        }
        if let expected = configuration.expectedModelSizeBytes,
           size.uint64Value != expected {
            return .invalidModel(
                path: url.path,
                reason: "expected \(expected) bytes, found \(size.uint64Value)"
            )
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .invalidModel(path: url.path, reason: "file is unreadable")
        }
        defer { try? handle.close() }
        let magic = try? handle.read(upToCount: WhisperBackendContract.modelMagic.count)
        guard magic == WhisperBackendContract.modelMagic else {
            return .invalidModel(path: url.path, reason: "GGML header is missing")
        }
        return nil
    }

    private func probeBackend(
        at resolvedPath: ResolvedDependencyPath
    ) -> Result<WhisperBackendDiagnostic, TalkTextDependencyPreflightFailure> {
        guard let help = probeRunner.run(executableURL: resolvedPath.url, arguments: ["--help"]),
              help.terminationStatus == 0 else {
            return .failure(.backendProbeFailed(path: resolvedPath.url.path))
        }

        let missingOptions = WhisperBackendContract.requiredOptions.filter { !help.output.contains($0) }
        guard missingOptions.isEmpty else {
            return .failure(.backendMissingOptions(path: resolvedPath.url.path, options: missingOptions))
        }

        guard let version = backendVersion(for: resolvedPath.url), !version.isEmpty else {
            return .failure(.backendVersionUnreported(path: resolvedPath.url.path))
        }
        guard WhisperBackendContract.supportedVersions.contains(version) else {
            return .failure(.unsupportedBackendVersion(
                path: resolvedPath.url.path,
                version: version,
                supported: WhisperBackendContract.supportedVersions
            ))
        }

        return .success(WhisperBackendDiagnostic(
            executable: resolvedPath,
            version: version,
            compatibility: "version-and-capability-verified"
        ))
    }

    private func backendVersion(for executableURL: URL) -> String? {
        if let configured = nonemptyEnvironmentValue("TALKTEXT_WHISPER_CLI_VERSION") {
            return normalizedVersion(configured)
        }

        let sidecarURL = URL(fileURLWithPath: executableURL.path + ".version")
        if let sidecar = try? String(contentsOf: sidecarURL, encoding: .utf8),
           let normalized = normalizedVersion(sidecar) {
            return normalized
        }

        let components = canonical(executableURL).pathComponents
        if let cellarIndex = components.firstIndex(of: "Cellar"),
           components.indices.contains(cellarIndex + 2),
           components[cellarIndex + 1] == WhisperBackendContract.formulaName,
           let normalized = normalizedVersion(components[cellarIndex + 2]) {
            return normalized
        }

        guard let output = probeRunner.run(executableURL: executableURL, arguments: ["--version"]) else {
            return nil
        }
        return versionReported(in: output.output)
    }

    private func versionReported(in output: String) -> String? {
        let pattern = #"(?i)version[^0-9]*([0-9]+\.[0-9]+\.[0-9]+)"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: output,
                  range: NSRange(output.startIndex..., in: output)
              ),
              let range = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return normalizedVersion(String(output[range]))
    }

    private func normalizedVersion(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        guard value.range(of: #"^[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private func nonemptyEnvironmentValue(_ key: String) -> String? {
        guard let value = configuration.environment[key],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    private func configuredURL(for path: String) -> URL {
        let expanded: String = if path == "~" {
            configuration.homeDirectoryURL.path
        } else if path.hasPrefix("~/") {
            configuration.homeDirectoryURL.appendingPathComponent(String(path.dropFirst(2))).path
        } else {
            path
        }

        if (expanded as NSString).isAbsolutePath {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }
        return configuration.currentDirectoryURL.appendingPathComponent(expanded).standardizedFileURL
    }

    private func pathEntries() -> [URL] {
        guard let path = configuration.environment["PATH"] else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: false).map { entry in
            entry.isEmpty
                ? configuration.currentDirectoryURL
                : configuredURL(for: String(entry))
        }
    }

    private func homebrewPrefixes() -> [URL] {
        var prefixes: [URL] = []
        if let configured = nonemptyEnvironmentValue("HOMEBREW_PREFIX") {
            prefixes.append(configuredURL(for: configured))
        }
        prefixes.append(contentsOf: configuration.homebrewPrefixes)
        return deduplicated(prefixes.map { ($0, DependencySearchSource.homebrew) }).map(\.0)
    }

    private func developmentRoots() -> [URL] {
        var roots = configuration.additionalDevelopmentRoots
        if let configured = nonemptyEnvironmentValue("TALKTEXT_DEVELOPMENT_ROOT") {
            roots.insert(configuredURL(for: configured), at: 0)
        }

        if let executableURL = configuration.executableURL,
           let inferred = repositoryRoot(forSwiftPMExecutable: executableURL) {
            roots.append(inferred)
        }

        roots.append(configuration.currentDirectoryURL)
        roots.append(configuration.currentDirectoryURL.deletingLastPathComponent())
        return deduplicated(roots.map { ($0, DependencySearchSource.development) }).map(\.0)
    }

    private func repositoryRoot(forSwiftPMExecutable executableURL: URL) -> URL? {
        var cursor = executableURL.deletingLastPathComponent()
        while cursor.path != "/" {
            if cursor.lastPathComponent == ".build" {
                let packageRoot = cursor.deletingLastPathComponent()
                return packageRoot.deletingLastPathComponent()
            }
            cursor.deleteLastPathComponent()
        }
        return nil
    }

    private func isReadableRegularFile(_ url: URL) -> Bool {
        guard FileManager.default.isReadableFile(atPath: url.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let type = attributes[.type] as? FileAttributeType else {
            return false
        }
        return type == .typeRegular
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func deduplicated(
        _ candidates: [(URL, DependencySearchSource)]
    ) -> [(URL, DependencySearchSource)] {
        var seen: Set<String> = []
        return candidates.filter { candidate in
            seen.insert(candidate.0.standardizedFileURL.path).inserted
        }
    }
}

private extension TalkTextDependencyPreflightFailure {
    var missingDependency: MissingWhisperDependency {
        switch self {
        case .missingModel, .invalidModel:
            .model
        case let .invalidOverride(variable, _, _):
            variable == "TALKTEXT_MODEL_PATH" ? .model : .binary
        default:
            .binary
        }
    }
}
