import Foundation
@testable import Leeway

/// One test at a time with `TestNetwork`, which is the whole app's: Swift Testing runs suites
/// side by side, and two tests' requests would land in each other's records.
actor NetworkLock {
    static let shared = NetworkLock()

    private var busy = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty { busy = false } else { waiting.removeFirst().resume() }
    }
}

/// Runs `body` with every request answered by `respond` (nil: no signal), then gives back the
/// requests it made. Nothing reaches the real network meanwhile.
@discardableResult
func withNetwork<T>(_ respond: @escaping @Sendable (URLRequest) -> TestNetwork.Answer? = { _ in nil },
                    _ body: () async throws -> T) async rethrows -> (result: T, made: [TestNetwork.Made]) {
    await NetworkLock.shared.acquire()
    TestNetwork.start(respond)
    defer {
        TestNetwork.stop()
        Task { await NetworkLock.shared.release() }
    }
    let result = try await body()
    return (result, TestNetwork.made)
}
