import Foundation
import Testing

/// Minimal callback expectation for Swift Testing, which has no `XCTestExpectation`.
/// `fulfill()` may be called from any thread and any number of times; `wait` reports
/// whether the first fulfillment happened before the timeout.
final class TestExpectation: @unchecked Sendable {
    let description: String
    private let lock = NSLock()
    private var fulfilled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ description: String) { self.description = description }

    func fulfill() {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            fulfilled = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    func wait(timeout: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let alreadyFulfilled = self.lock.withLock { () -> Bool in
                        if !self.fulfilled { self.waiters.append(continuation) }
                        return self.fulfilled
                    }
                    if alreadyFulfilled { continuation.resume() }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func expectFulfilled(timeout: TimeInterval, sourceLocation: SourceLocation = #_sourceLocation) async {
        let ok = await wait(timeout: timeout)
        #expect(ok, Comment(rawValue: "Timed out waiting: \(description)"), sourceLocation: sourceLocation)
    }
}
