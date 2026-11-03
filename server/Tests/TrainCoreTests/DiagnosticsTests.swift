import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import Testing
@testable import TrainCore

/// A report as the app sends one (ios/App/Diagnostics.swift, `Diagnostics.report`).
func diagnosticsBody(kind: String = "crash", log: Any? = "2026-11-01T14:03:22Z notice PushServer: refused\n",
                     padding: Int = 0) throws -> [UInt8] {
    var json: [String: Any] = [
        "kind": kind, "app": "1.0 (3)", "os": "iOS Version 27.1 (Build 24B5)", "device": "iPhone17,1",
        "metricKit": ["crashDiagnostics": [["diagnosticMetaData": ["exceptionType": 1]]], "pad": String(repeating: "x", count: padding)],
    ]
    if let log { json["log"] = log }
    return Array(try JSONSerialization.data(withJSONObject: json))
}

@Suite struct DiagnosticStoreTests {
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("traintimes-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func takesOnlyReportsAsTheAppSends() throws {
        #expect(DiagnosticStore.kind(of: try diagnosticsBody()) == "crash")
        #expect(DiagnosticStore.kind(of: try diagnosticsBody(kind: "hang", log: nil)) == "hang")
        #expect(DiagnosticStore.kind(of: try diagnosticsBody(kind: "../../etc")) == nil)
        #expect(DiagnosticStore.kind(of: try diagnosticsBody(log: 3)) == nil)
        #expect(DiagnosticStore.kind(of: Array("not json".utf8)) == nil)
        #expect(DiagnosticStore.kind(of: Array("[1, 2]".utf8)) == nil)
        let noMetricKit = try JSONSerialization.data(withJSONObject: ["kind": "crash", "app": "1", "os": "i", "device": "d"])
        #expect(DiagnosticStore.kind(of: noMetricKit) == nil)
    }

    @Test func savesPrivateFilesNamedByTimeAndKind() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try DiagnosticStore(directory: dir)
        let body = try diagnosticsBody()
        let name = try await store.save(body, kind: "crash", now: Date(timeIntervalSince1970: 1_793_541_802))
        #expect(name.hasPrefix("20261101-140322-crash-"))
        #expect(name.hasSuffix(".json"))
        #expect(try await store.body(named: name) == body)

        let folder = dir.appendingPathComponent(DiagnosticStore.directoryName)
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(name).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folderAttributes = try FileManager.default.attributesOfItem(atPath: folder.path)
        #expect((folderAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func dropsTheOldAndTheOldestOverTheLimit() async throws {
        let store = DiagnosticStore(maxReports: 3, retention: 30 * 86400)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var names: [String] = []
        for day in 0..<5 {
            names.append(try await store.save(try diagnosticsBody(), kind: "crash", now: start + Double(day) * 86400))
        }
        // Five saved, the newest three kept
        #expect(try await store.names == Array(names.suffix(3)))
        // A month after the second newest, only the newest is left
        #expect(try await store.prune(now: start + 3 * 86400 + 30 * 86400 + 1) == 2)
        #expect(try await store.names == [names[4]])
    }
}

@Suite struct DiagnosticsHTTPTests {
    let secret = "test-secret-0123456789abcdef"

    func withApp(limits: Limits = testLimits(),
                 _ body: @escaping @Sendable (any TestClientProtocol, DiagnosticStore) async throws -> Void) async throws {
        let diagnostics = DiagnosticStore()
        let services = HTTPServices(store: try Store(directory: nil), auth: .secret(secret), appID: testAppID,
                                    limits: limits, diagnostics: diagnostics)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in
            try await body(client, diagnostics)
        }
    }

    @Test func savesASignedReport() async throws {
        try await withApp { client, diagnostics in
            let body = try diagnosticsBody()
            try await client.execute(uri: "/diagnostics", method: .post, headers: [.authorization: "Bearer \(secret)"],
                                     body: ByteBuffer(bytes: body)) { #expect($0.status == .noContent) }
            let names = try await diagnostics.names
            #expect(names.count == 1)
            #expect(try await diagnostics.body(named: try #require(names.first)) == body)
        }
    }

    @Test func refusesUnsignedMalformedAndOversizedReports() async throws {
        try await withApp { client, diagnostics in
            try await client.execute(uri: "/diagnostics", method: .post,
                                     body: ByteBuffer(bytes: try diagnosticsBody())) { #expect($0.status == .unauthorized) }
            let bearer: HTTPFields = [.authorization: "Bearer \(secret)"]
            try await client.execute(uri: "/diagnostics", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try diagnosticsBody(kind: "nope"))) { #expect($0.status == .badRequest) }
            try await client.execute(uri: "/diagnostics", method: .post, headers: bearer,
                                     body: ByteBuffer(bytes: try diagnosticsBody(padding: AppContext.diagnosticsBodyLimit))) {
                #expect($0.status == .contentTooLarge)
            }
            #expect(try await diagnostics.names.isEmpty)
        }
    }

    @Test func capsEachKeysReportsADay() async throws {
        var limits = testLimits()
        limits.diagnosticsPerKeyPerDay = 2
        try await withApp(limits: limits) { client, diagnostics in
            let bearer: HTTPFields = [.authorization: "Bearer \(secret)"]
            for status in [HTTPResponse.Status.noContent, .noContent, .tooManyRequests] {
                try await client.execute(uri: "/diagnostics", method: .post, headers: bearer,
                                         body: ByteBuffer(bytes: try diagnosticsBody())) { response in
                    #expect(response.status == status)
                    if status == .tooManyRequests { #expect(response.headers[.retryAfter] != nil) }
                }
            }
            #expect(try await diagnostics.names.count == 2)
        }
    }

    @Test func takesReportsSignedWithAnAttestKey() async throws {
        let store = try Store(directory: nil)
        let authority = try TestAuthority()
        let diagnostics = DiagnosticStore()
        let services = HTTPServices(store: store, auth: .attest([.production]), appID: testAppID, limits: testLimits(),
                                    roots: [authority.root], diagnostics: diagnostics)
        try await Application(router: HTTPRoutes.router(services)).test(.router) { client in
            let device = TestDevice()
            #expect(try await AttestModeHTTPTests.attest(device, client, authority) == .noContent)
            let body = try diagnosticsBody()
            let headers = try device.headers(challenge: try await AttestModeHTTPTests.challenge(client), method: "POST",
                                             path: "/diagnostics", body: body)
            try await client.execute(uri: "/diagnostics", method: .post, headers: headers,
                                     body: ByteBuffer(bytes: body)) { #expect($0.status == .noContent) }
            // Signed for another route
            let other = try device.headers(challenge: try await AttestModeHTTPTests.challenge(client), method: "POST",
                                           path: "/activities", body: body)
            try await client.execute(uri: "/diagnostics", method: .post, headers: other,
                                     body: ByteBuffer(bytes: body)) { #expect($0.status == .unauthorized) }
            #expect(try await diagnostics.names.count == 1)
        }
    }
}
