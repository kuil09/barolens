import Foundation
import OSLog

enum AsyncStageError: LocalizedError {
    case timedOut
    var errorDescription: String? { L10n.text("The operation took too long. Please try again.") }
}

/// Cancellation and a deadline release the caller even when a framework ignores cancellation.
/// A task group cannot do this: leaving its scope waits for every child to return.
@MainActor enum AsyncStage {
    static func run<Value: Sendable>(timeout: Duration = .seconds(15), stage: String,
                           operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let pending = Pending<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending.continuation = continuation
                pending.work = Task {
                    do { pending.finish(.success(try await operation())) }
                    catch { pending.finish(.failure(error)) }
                }
                pending.deadline = Task {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    Logger(subsystem: "dev.local.barolens", category: "Startup")
                        .error("Service deadline exceeded: \(stage, privacy: .public)")
                    pending.finish(.failure(AsyncStageError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor in pending.finish(.failure(CancellationError())) }
        }
    }

    @MainActor private final class Pending<Value: Sendable> {
        var continuation: CheckedContinuation<Value, any Error>?
        var work: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        func finish(_ result: Result<Value, any Error>) {
            guard let continuation else { return }
            self.continuation = nil
            work?.cancel(); deadline?.cancel()
            work = nil; deadline = nil
            continuation.resume(with: result)
        }
    }
}
