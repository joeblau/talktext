import Foundation

@MainActor
final class LiveTextStreamingPresenter {
    private var targetText = ""
    private var displayedText = ""
    private var task: Task<Void, Never>?
    private var generation = 0

    func present(
        _ text: String,
        deliver: @escaping @MainActor (String) async -> Void
    ) {
        targetText = text
        guard task == nil else { return }
        generation += 1
        let generation = generation
        task = Task { @MainActor [weak self] in
            await self?.run(generation: generation, deliver: deliver)
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        targetText = ""
        displayedText = ""
    }

    private func run(
        generation: Int,
        deliver: @escaping @MainActor (String) async -> Void
    ) async {
        defer {
            if generation == self.generation { task = nil }
        }
        while !Task.isCancelled, generation == self.generation {
            if targetText == displayedText { return }
            let next = if targetText.hasPrefix(displayedText) {
                String(targetText.prefix(displayedText.count + 2))
            } else {
                targetText
            }
            displayedText = next
            await deliver(next)
            do {
                try await Task.sleep(for: .milliseconds(16))
            } catch {
                return
            }
        }
    }
}
