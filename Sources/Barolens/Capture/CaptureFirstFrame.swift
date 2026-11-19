import Foundation

/// A complete frame may arrive before startCapture's completion callback.
/// Remember it, while rejecting frames and waiters from superseded streams.
@MainActor final class CaptureFirstFrame {
    private var generation: UInt64 = 0
    private var received = false
    private var waiter: CheckedContinuation<Void, any Error>?

    func reset(to generation: UInt64) {
        waiter?.resume(throwing: CancellationError()); waiter = nil
        self.generation = generation; received = false
    }
    func accept(_ generation: UInt64) {
        guard self.generation == generation else { return }
        received = true
        waiter?.resume(); waiter = nil
    }
    func wait(for generation: UInt64, timeout: Duration = .seconds(5)) async throws {
        try await AsyncStage.run(timeout: timeout, stage: "firstFrame") { [self] in
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            if received { return }
            try await withCheckedThrowingContinuation { waiter = $0 }
        }
    }
}
