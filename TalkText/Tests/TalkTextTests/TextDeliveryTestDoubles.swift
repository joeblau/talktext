import AppKit
import Foundation
@testable import TalkText

@MainActor
final class DeliveryFakeLiveTextEditor: LiveTextEditing {
    var updateOutcome: LiveTextUpdateOutcome = .updated
    var finalizationOutcome: LiveTextFinalizationOutcome = .finalized
    var cancellationOutcome: LiveTextCancellationOutcome = .restored
    private(set) var updatedTexts: [String] = []
    private(set) var finalizedTexts: [String] = []
    private(set) var cancelCount = 0

    func update(_ text: String, in target: PasteTarget) async -> LiveTextUpdateOutcome {
        updatedTexts.append(text)
        return updateOutcome
    }

    func finalize(_ text: String, in target: PasteTarget) async -> LiveTextFinalizationOutcome {
        finalizedTexts.append(text)
        return finalizationOutcome
    }

    func cancel() async -> LiveTextCancellationOutcome {
        cancelCount += 1
        return cancellationOutcome
    }
}

@MainActor
final class DeliveryFakeWorkspace: WorkspaceServing {
    let capturedTarget: PasteTarget?
    var frontmost: PasteTarget?
    var availability: TargetProcessAvailability = .available
    var availabilitySequence: [TargetProcessAvailability] = []
    var availabilityResolver: ((PasteTarget) -> TargetProcessAvailability)?
    var activationOutcome: TargetActivationOutcome = .requested
    var frontmostAfterActivationCount: Int?
    private(set) var activationCount = 0

    init(capturedTarget: PasteTarget?, frontmost: PasteTarget?) {
        self.capturedTarget = capturedTarget
        self.frontmost = frontmost
    }

    func currentExternalTarget(excludingBundleIdentifier: String?) -> PasteTarget? {
        capturedTarget
    }

    func availability(of target: PasteTarget) -> TargetProcessAvailability {
        if let availabilityResolver {
            return availabilityResolver(target)
        }
        if !availabilitySequence.isEmpty {
            return availabilitySequence.removeFirst()
        }
        return availability
    }

    func activate(_ target: PasteTarget) -> TargetActivationOutcome {
        activationCount += 1
        if let threshold = frontmostAfterActivationCount, activationCount >= threshold {
            frontmost = target
        }
        return activationOutcome
    }

    func frontmostTarget() -> PasteTarget? {
        frontmost
    }
}

@MainActor
final class DeliveryFakeAccessibility: AccessibilityServing {
    var permission = true
    var insertionOutcome: AccessibilityInsertionOutcome
    var windowAvailabilityValue: TargetWindowAvailability
    private(set) var insertedTargets: [PasteTarget] = []

    init(
        insertionOutcome: AccessibilityInsertionOutcome,
        windowAvailability: TargetWindowAvailability = .available
    ) {
        self.insertionOutcome = insertionOutcome
        windowAvailabilityValue = windowAvailability
    }

    func ensurePermission(prompt: Bool) -> Bool {
        permission
    }

    func insert(_ text: String, into target: PasteTarget) -> AccessibilityInsertionOutcome {
        insertedTargets.append(target)
        return insertionOutcome
    }

    func windowAvailability(of target: PasteTarget) -> TargetWindowAvailability {
        windowAvailabilityValue
    }
}

@MainActor
final class DeliveryFakeEventPoster: PasteEventPosting {
    var permission = true
    var postResult = true
    private(set) var postedTargets: [PasteTarget] = []

    func ensurePermission(prompt: Bool) -> Bool {
        permission
    }

    func postPasteShortcut(to target: PasteTarget) -> Bool {
        postedTargets.append(target)
        return postResult
    }
}

@MainActor
final class DeliveryFakePasteboard: PasteboardServing {
    private(set) var changeCount = 1
    private(set) var currentString: String?
    private(set) var replaceTexts: [String] = []
    private(set) var restoreCount = 0
    private(set) var maximumConcurrentTransactions = 0
    var replacementFailure: PasteboardMutationFailure?
    var snapshotFailure: PasteboardSnapshotFailure?
    var restorationOutcome: ClipboardRestorationOutcome = .restored
    private var transactionDepth = 0

    func snapshot() -> Result<PasteboardSnapshot, PasteboardSnapshotFailure> {
        if let snapshotFailure {
            return .failure(snapshotFailure)
        }
        transactionDepth += 1
        maximumConcurrentTransactions = max(maximumConcurrentTransactions, transactionDepth)
        return .success(
            PasteboardSnapshot(
                items: [PasteboardItemSnapshot(representations: ["public.utf8-plain-text": Data("original".utf8)])]
            )
        )
    }

    func replaceContents(with text: String) -> PasteboardReplacementResult {
        replaceTexts.append(text)
        changeCount += 1
        if let replacementFailure {
            return .failed(replacementFailure, currentChangeCount: changeCount)
        }
        currentString = text
        return .replaced(changeCount: changeCount)
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        ifUnchangedSince changeCount: Int
    ) -> ClipboardRestorationOutcome {
        restoreCount += 1
        transactionDepth = max(0, transactionDepth - 1)
        if restorationOutcome == .restored {
            currentString = nil
            self.changeCount += 1
        }
        return restorationOutcome
    }
}

@MainActor
final class DeliveryImmediateSleeper: DeliverySleeping {
    func sleep(for duration: TimeInterval) async -> Bool {
        !Task.isCancelled
    }
}

@MainActor
final class DeliveryGateSleeper: DeliverySleeping {
    private var continuations: [CheckedContinuation<Bool, Never>] = []

    var pendingCount: Int {
        continuations.count
    }

    func sleep(for duration: TimeInterval) async -> Bool {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeNext(with result: Bool = true) {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume(returning: result)
    }
}
