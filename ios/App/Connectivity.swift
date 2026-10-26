import Foundation
import Network

/// Wakes refresh loops as soon as the network comes back or changes, as when a train pulls into
/// a station with signal or Wi-Fi after a tunnel, rather than when their timers next fire: below
/// ground, a station stop may be all the time there is to fetch.
@MainActor
final class Connectivity {
    static let shared = Connectivity()

    private let monitor = NWPathMonitor()
    private var path: NWPath?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    private init() {
        monitor.pathUpdateHandler = { path in
            Task { @MainActor in Connectivity.shared.update(path) }
        }
        monitor.start(queue: DispatchQueue(label: "Connectivity"))
    }

    /// Wakes every `pause` when there's a usable path that wasn't there before: back from none,
    /// or over other interfaces (station Wi-Fi joined, or LTE back). Not on the first path.
    private func update(_ new: NWPath) {
        let old = path
        path = new
        guard new.status == .satisfied, let old,
              old.status != .satisfied || old.availableInterfaces.map(\.name) != new.availableInterfaces.map(\.name)
        else { return }
        let woken = waiters.values
        waiters = [:]
        for waiter in woken {
            waiter.resume()
        }
    }

    /// Sleeps for `duration`, or until the network comes back (`update`), whichever is first.
    func pause(for duration: Duration) async {
        let id = UUID()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await Task.sleep(for: duration) }
            group.addTask { await self.networkBack(id) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Returns when the network comes back, or when cancelled.
    private func networkBack(_ id: UUID) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                // Cancelled before it could wait
                guard !Task.isCancelled else { return continuation.resume() }
                waiters[id] = continuation
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
        }
    }
}
