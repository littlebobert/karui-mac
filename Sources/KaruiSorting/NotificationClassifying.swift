import Foundation

public protocol NotificationClassifying: Sendable {
    func classify(_ notification: NotificationInput, policy: TriagePolicy) async -> TriageResult
}
