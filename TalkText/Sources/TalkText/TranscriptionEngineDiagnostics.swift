import Foundation
import os

private let dependencyLogger = Logger(
    subsystem: AppIdentity.bundleIdentifier,
    category: "engine"
)

extension TranscriptionEngine {
    func logTemporaryFileError(operation: StaticString, error: any Error) {
        let errorType = String(describing: type(of: error))
        dependencyLogger.error(
            "Temporary recording \(operation, privacy: .public) failed; error type: \(errorType, privacy: .public)"
        )
    }

    func logTranscriptionOutcome(_ outcome: TranscriptionOutcome) {
        switch outcome {
        case let .success(text):
            dependencyLogger.notice("Transcription succeeded; characters: \(text.count, privacy: .public)")
        case .noSpeech:
            dependencyLogger.notice("Transcription succeeded with no speech")
        case let .missingDependency(dependency):
            dependencyLogger.error(
                "Transcription dependency missing; kind: \(String(describing: dependency), privacy: .public)"
            )
        case let .invalidAudio(reason):
            dependencyLogger.error(
                "Transcription rejected invalid audio; reason: \(String(describing: reason), privacy: .public)"
            )
        case let .launchFailed(diagnostic):
            dependencyLogger.error(
                "Transcription process launch failed; domain: \(diagnostic.launchErrorDomain ?? "unknown", privacy: .private), code: \(diagnostic.launchErrorCode ?? -1, privacy: .public)"
            )
        case let .processFailed(diagnostic):
            logProcessDiagnostic("failed", diagnostic: diagnostic)
        case let .timedOut(diagnostic):
            logProcessDiagnostic("timed out", diagnostic: diagnostic)
        case let .cancelled(diagnostic):
            logProcessDiagnostic("cancelled", diagnostic: diagnostic)
        }
    }

    func logProcessDiagnostic(_ outcome: StaticString, diagnostic: ProcessDiagnostic) {
        dependencyLogger.error(
            "Transcription process \(outcome, privacy: .public); reason: \(String(describing: diagnostic.terminationReason), privacy: .public), status: \(diagnostic.terminationStatus ?? -1, privacy: .public), stdout bytes: \(diagnostic.standardOutput.count, privacy: .public), stderr bytes: \(diagnostic.standardError.count, privacy: .public)"
        )
    }

    func dependencyPreflightResult() async -> TalkTextDependencyPreflightResult {
        if let cachedDependencyPreflight {
            return cachedDependencyPreflight
        }
        if let dependencyPreparationTask {
            return await dependencyPreparationTask.value
        }

        let preflight = dependencyPreflight
        let task = Task {
            await preflight.preflightDependencies()
        }
        dependencyPreparationTask = task
        let result = await task.value
        dependencyPreparationTask = nil
        cachedDependencyPreflight = result
        logDependencyPreflight(result)
        return result
    }

    func logDependencyPreflight(_ result: TalkTextDependencyPreflightResult) {
        switch result {
        case let .ready(preflight):
            dependencyLogger.notice(
                "Dependency preflight ready; \(preflight.diagnosticSummary, privacy: .public); binary: \(preflight.backend.executable.url.path, privacy: .private(mask: .hash)); model: \(preflight.model.url.path, privacy: .private(mask: .hash))"
            )
        case let .failure(failure):
            dependencyLogger.error(
                "Dependency preflight failed; category: \(Self.preflightFailureCategory(failure), privacy: .public)"
            )
        }
    }
}
