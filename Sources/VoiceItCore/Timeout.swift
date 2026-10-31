import Foundation

/// Runs `operation` and gives up on it after `seconds`, returning nil (and cancelling it) on timeout or error.
/// Unlike a task group, this returns at the deadline even if the operation is slow to stop.
public func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async -> T? {
    await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
        let once = Once(continuation)
        let work = Task {
            do { once.resume(try await operation()) } catch { once.resume(nil) }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if once.resume(nil) { work.cancel() }
        }
    }
}

private final class Once<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    init(_ c: CheckedContinuation<T?, Never>) { continuation = c }
    @discardableResult
    func resume(_ value: T?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let c = continuation else { return false }
        continuation = nil
        c.resume(returning: value)
        return true
    }
}
