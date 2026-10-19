import Foundation

enum Concurrency {
    /// `transform` on each of `items`, at most `limit` at a time, results in any order.
    static func map<T: Sendable, R: Sendable>(_ items: [T], limit: Int,
                                              _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
        await withTaskGroup(of: R.self) { group in
            var results: [R] = []
            results.reserveCapacity(items.count)
            var next = items.makeIterator()
            for _ in 0..<max(1, limit) {
                guard let item = next.next() else { break }
                group.addTask { await transform(item) }
            }
            while let result = await group.next() {
                results.append(result)
                if let item = next.next() {
                    group.addTask { await transform(item) }
                }
            }
            return results
        }
    }

    struct TimedOut: Error, CustomStringConvertible {
        var description: String { "timed out" }
    }

    /// `body`, cancelled after `seconds`.
    static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                         _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw TimedOut() }
            return result
        }
    }
}
