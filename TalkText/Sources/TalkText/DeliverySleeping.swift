import Foundation

@MainActor
protocol DeliverySleeping: AnyObject {
    func sleep(for duration: TimeInterval) async -> Bool
}

@MainActor
final class SystemDeliverySleeper: DeliverySleeping {
    func sleep(for duration: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(max(0, duration)))
            return true
        } catch {
            return false
        }
    }
}
