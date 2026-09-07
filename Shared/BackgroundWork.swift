import Foundation

/// Explicitly leave the caller's actor for CPU work, forwarding cancellation.
enum BackgroundWork {
    static func run<Value: Sendable>(
        priority: TaskPriority = .userInitiated,
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let worker = Task.detached(priority: priority) {
            try Task.checkCancellation()
            let value = try operation()
            try Task.checkCancellation()
            return value
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
