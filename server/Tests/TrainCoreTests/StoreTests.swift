import Foundation
import Testing
@testable import TrainCore

@Suite struct StoreTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("traintimes-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func key(_ id: String = "k", lastUsed: Date = now) -> AttestKey {
        AttestKey(id: id, publicKey: Data(repeating: 4, count: 65), counter: 0, environment: .production,
                  created: lastUsed, lastUsed: lastUsed)
    }

    @Test func survivesARestartInWALMode() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try Store(directory: dir)
        _ = try await store.upsert(testRegistration(), maxTotal: 10, maxPerOwner: 5)
        try await store.apply([.pushed(token: sampleToken, revision: try #require(await store.registration(for: sampleToken)).revision,
                                       state: state(train: 4, trip: "z"), at: now)])
        #expect(try await store.addKey(key()))

        let reloaded = try Store(directory: dir)
        let registration = try #require(await reloaded.registration(for: sampleToken))
        #expect(registration == (await store.registration(for: sampleToken)))
        #expect(registration.lastState == state(train: 4, trip: "z"))
        #expect(registration.trip == "z")
        #expect(try await reloaded.key(id: "k") == key())
        #expect(await reloaded.count(ownedBy: "key") == 1)

        let file = dir.appendingPathComponent(Store.fileName).path
        #expect(try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? Int == 0o600)
        #expect(FileManager.default.fileExists(atPath: file + "-wal"))
    }

    @Test func migratesRegistrationsJSONOnce() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let last = state(train: 2)
        // As the old RegistrationStore wrote it
        let legacy: [[String: Any]] = [[
            "token": sampleToken, "environment": "sandbox",
            "selection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prospect)),
            "trip": "b", "started": now.timeIntervalSinceReferenceDate, "alertKinds": [0],
            "revision": UUID().uuidString,
            "lastState": try JSONSerialization.jsonObject(with: JSONEncoder().encode(last)),
            "lastPush": now.timeIntervalSinceReferenceDate,
        ]]
        let file = dir.appendingPathComponent(Store.legacyFileName)
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)

        let store = try Store(directory: dir)
        let migrated = try #require(await store.registration(for: sampleToken))
        #expect(migrated.owner == Owner.legacy)
        #expect(migrated.environment == .sandbox)
        #expect(migrated.selection == prospect)
        #expect(migrated.alertKinds == [.delays])
        #expect(migrated.lastState == last)
        #expect(migrated.lastPush == now)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // Again, with the file back: what's already there isn't duplicated or replaced
        try JSONSerialization.data(withJSONObject: legacy).write(to: file)
        let again = try Store(directory: dir)
        #expect(await again.count == 1)
        #expect(await again.registration(for: sampleToken) == migrated)
    }

    @Test func startsDespiteRowsItCantRead() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        func token(_ i: Int) -> String { String(format: "%064x", i) }
        let store = try Store(directory: dir)
        for i in 1...3 {
            _ = try await store.upsert(testRegistration(token: token(i)), maxTotal: 10, maxPerOwner: 5)
        }
        try await store.apply([.pushed(token: token(1), revision: try #require(await store.registration(for: token(1))).revision,
                                       state: state(train: 4), at: now)])

        // As a build with another field in ContentState, or an alert kind or direction fewer, might find them
        var last = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(state(train: 4))) as? [String: Any])
        last["updated"] = nil
        let db = try SQLite(path: dir.appendingPathComponent(Store.fileName).path)
        try db.query("UPDATE registrations SET last_state = ?, alert_kinds = ? WHERE token = ?", [
            .blob(try JSONSerialization.data(withJSONObject: last)), .blob(Data("[0,9]".utf8)), .text(token(1)),
        ])
        try db.query("UPDATE registrations SET selection = ? WHERE token = ?", [
            .blob(Data(#"{"stationID":"R34","routes":["R"],"direction":"X"}"#.utf8)), .text(token(2)),
        ])

        let reloaded = try Store(directory: dir)
        // Kept, to be pushed afresh
        let partly = try #require(await reloaded.registration(for: token(1)))
        #expect(partly.lastState == nil)
        #expect(partly.alertKinds == nil)
        #expect(partly.lastPush == now)
        #expect(partly.selection == prospect)
        // Dropped, from the database too
        #expect(await reloaded.registration(for: token(2)) == nil)
        #expect(try db.query("SELECT token FROM registrations ORDER BY token").map { $0.first?.text } == [token(1), token(3)])
        #expect(await reloaded.registration(for: token(3)) == (await store.registration(for: token(3))))
        #expect(await reloaded.count == 2)
    }

    @Test func migratesTheLegacyEntriesItCanRead() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(Store.legacyFileName)
        let good: [String: Any] = [
            "token": sampleToken, "environment": "sandbox",
            "selection": try JSONSerialization.jsonObject(with: JSONEncoder().encode(prospect)),
            "trip": "b", "started": now.timeIntervalSinceReferenceDate, "revision": UUID().uuidString,
            "alertKinds": [0, 9], "lastState": ["trip": "b"], "lastPush": now.timeIntervalSinceReferenceDate,
        ]
        var bad = good
        bad["token"] = String(repeating: "cd34", count: 16)
        bad["environment"] = "staging"
        try JSONSerialization.data(withJSONObject: [bad, good]).write(to: file)

        let store = try Store(directory: dir)
        #expect(await store.count == 1)
        let migrated = try #require(await store.registration(for: sampleToken))
        #expect(migrated.selection == prospect)
        #expect(migrated.alertKinds == nil)
        #expect(migrated.lastState == nil)
        #expect(migrated.lastPush == now)
        #expect(!FileManager.default.fileExists(atPath: file.path))

        // A file that can't be read at all is left for someone to look at
        try Data("[{".utf8).write(to: file)
        let again = try Store(directory: dir)
        #expect(await again.count == 1)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func capsTotalsAndOwners() async throws {
        let store = try Store(directory: nil)
        func token(_ i: Int) -> String { String(format: "%064x", i) }
        for i in 1...3 {
            #expect(try await store.upsert(testRegistration(token: token(i), owner: "a", started: now + Double(i)),
                                           maxTotal: 4, maxPerOwner: 2) != .full)
        }
        // The oldest of a's went to make room
        #expect(await store.count(ownedBy: "a") == 2)
        #expect(await store.registration(for: token(1)) == nil)
        #expect(try await store.upsert(testRegistration(token: token(4), owner: "b"), maxTotal: 3, maxPerOwner: 2) == .saved(evicted: []))
        #expect(try await store.upsert(testRegistration(token: token(5), owner: "c"), maxTotal: 3, maxPerOwner: 2) == .full)
        // Replacing one's own isn't growing
        #expect(try await store.upsert(testRegistration(token: token(4), owner: "b"), maxTotal: 3, maxPerOwner: 2) == .saved(evicted: []))
        #expect(try await store.upsert(testRegistration(token: token(4), owner: "a"), maxTotal: 3, maxPerOwner: 2) == .ownedByOther)
        #expect(try await store.remove(token(4), owner: "a") == .notOwner)
        #expect(try await store.remove(token(4), owner: "b") == .removed)
        #expect(try await store.remove(token(4), owner: "b") == .notFound)
    }

    @Test func countersOnlyRise() async throws {
        let store = try Store(directory: nil)
        #expect(try await store.addKey(key()))
        #expect(try await !store.addKey(key()))
        #expect(try await store.advanceCounter(keyID: "k", to: 3, now: now))
        #expect(try await !store.advanceCounter(keyID: "k", to: 3, now: now))
        #expect(try await !store.advanceCounter(keyID: "k", to: 2, now: now))
        #expect(try await store.advanceCounter(keyID: "k", to: 4, now: now + 5))
        #expect(try await store.key(id: "k")?.counter == 4)
        #expect(try await store.key(id: "k")?.lastUsed == now + 5)
        #expect(try await !store.advanceCounter(keyID: "unknown", to: 9, now: now))
    }

    @Test func purgesKeysUnusedFor90DaysWithTheirRegistrations() async throws {
        let store = try Store(directory: nil)
        let old = now - 91 * 86400
        #expect(try await store.addKey(key("old", lastUsed: old)))
        #expect(try await store.addKey(key("recent", lastUsed: now - 86400)))
        _ = try await store.upsert(testRegistration(owner: "old"), maxTotal: 10, maxPerOwner: 5)
        let poller = Poller(store: store, pusher: FakePusher(), interval: 30) { _, _ in [:] }
        await poller.purge(now: now)
        #expect(try await store.key(id: "old") == nil)
        #expect(try await store.key(id: "recent") != nil)
        #expect(await store.count == 0)
    }
}
