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
        case let .modelUnavailable(failure):
            dependencyLogger.error("Parakeet model unavailable; category: \(Self.preflightFailureCategory(failure), privacy: .public)")
        case let .invalidAudio(reason):
            dependencyLogger.error("Transcription rejected invalid audio; reason: \(String(describing: reason), privacy: .public)")
        case let .inferenceFailed(diagnostic):
            dependencyLogger.error("Parakeet inference failed; domain: \(diagnostic.domain, privacy: .private), code: \(diagnostic.code, privacy: .public)")
        case .cancelled:
            dependencyLogger.notice("Transcription cancelled")
        }
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
                "Dependency preflight ready; \(preflight.diagnosticSummary, privacy: .public); model: \(preflight.model.url.path, privacy: .private(mask: .hash))"
            )
        case let .failure(failure):
            dependencyLogger.error(
                "Dependency preflight failed; category: \(Self.preflightFailureCategory(failure), privacy: .public)"
            )
        }
    }
}
