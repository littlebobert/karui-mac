import Foundation
import Synchronization

/// Gives up on on-device model work that doesn't finish in time. A model request can
/// occasionally hang without failing, and awaiting it would stall the Shortcut, the
/// daily summary, or a batch rerun indefinitely. The operation runs in its own task
/// and is cancelled on timeout, but the caller never waits past the deadline even if
/// it ignores cancellation.
public enum ModelDeadline {
    public static let classification: Duration = .seconds(20)
    public static let summary: Duration = .seconds(30)

    public static func value<T: Sendable>(
        within deadline: Duration,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let work = Task { await operation() }
        let isResolved = Mutex(false)
        return await withCheckedContinuation { continuation in
            let resolve: @Sendable (T?) -> Void = { value in
                let isFirst = isResolved.withLock { resolved in
                    defer { resolved = true }
                    return !resolved
                }
                if isFirst { continuation.resume(returning: value) }
            }
            Task {
                resolve(await work.value)
            }
            Task {
                try? await Task.sleep(for: deadline)
                work.cancel()
                resolve(nil)
            }
        }
    }
}
