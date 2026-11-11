import CoreLocation
import Foundation
import Testing
import UIKit
@testable import Leeway

/// What must never leave the phone: the user's name and email, the device's name, and this
/// machine's user. Lowercased.
private func personalNeedles() async -> [String] {
    var needles = ["ben", "wilsker", "@gmail"]
    needles.append(await MainActor.run { UIDevice.current.name })
    needles += NSFullUserName().split(separator: " ").map(String.init)
    needles.append(NSUserName())
    return Set(needles.map { $0.lowercased() }.filter { $0.count >= 3 && $0 != "mobile" && $0 != "root" }).sorted()
}

/// Each request that carries one of `needles`, or sets its own User-Agent, as a line saying where.
private func leaks(in made: [TestNetwork.Made], needles: [String]) -> [String] {
    made.flatMap { request -> [String] in
        let url = request.url.absoluteString.lowercased()
        let decoded = (request.url.absoluteString.removingPercentEncoding ?? "").lowercased()
        let headers = request.headers.map { "\($0.key): \($0.value)" }.joined(separator: "\n").lowercased()
        let body = request.body.map { String(decoding: $0, as: UTF8.self).lowercased() } ?? ""
        var found = needles.flatMap { needle -> [String] in
            [("URL", url + "\n" + decoded), ("headers", headers), ("body", body)]
                .filter { $0.1.contains(needle) }
                .map { "\(request.method) \(request.url.path): \"\(needle)\" in its \($0.0)" }
        }
        if request.headers.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            found.append("\(request.method) \(request.url.path) sets its own User-Agent")
        }
        return found
    }
}

/// Every request-making path the app has without a device: feeds, boards, alerts, trips, buses,
/// docks, the timetable, the push server and Siri.
private func driveEveryRequest() async {
    _ = await TrainService.optionalData(from: WNSupport.uniqueFeed())
    _ = try? await TrainService.board(for: Selection(stationID: "L29", routes: ["L"], direction: .south))
    _ = try? await TrainService.board(for: .fallback, includingAlerts: true, includingOutages: true)
    _ = await TrainService.notices(for: Selection(stationID: "A27", routes: ["A", "C", "E"], direction: .south,
                                                  elevatorAlerts: true))
    _ = await TrainService.alertEntries(routes: ["WN\(UUID().uuidString.prefix(6))"])
    let here = WNSupport.uniqueLocation()
    let there = WNSupport.uniqueLocation()
    _ = await ServerRoutes.fetchRoutes(from: here, to: there, at: Date(timeIntervalSince1970: 1_950_000_000), buses: true)
    _ = await BusTimes.arrivals(lines: ["B63", "B103"],
                                at: BusRide.Place(name: "x", latitude: here.coordinate.latitude,
                                                  longitude: here.coordinate.longitude))
    _ = await NearbyBuses.places(near: here, wait: 1)
    _ = await CitiBike.docks(near: there)
    _ = await CitiBike.docks(ids: ["wn-\(UUID().uuidString)"])
    let (file, name) = WNSupport.timetableFile()
    await file.refresh(force: true)
    WNSupport.removeTimetable(name)
    let registration = PushRegistration(token: "00ff", environment: PushServer.environment, selection: .fallback,
                                        trip: "trip", alertKinds: [0, 1, 2, 3])
    try? await PushServer.shared.register(registration)
    try? await PushServer.shared.unregister(token: "00ff")
    try? await PushServer.shared.sendDiagnostics(Data("{}".utf8))
    let intent = NextTrainIntent()
    intent.stop = StopEntity(stationID: "R20", direction: .south, routes: ["Q"])
    _ = try? await intent.perform()
    // Extras a failed board started go on a moment after it
    try? await Task.sleep(for: .seconds(2.5))
}

/// Hosts the app may ask: the push server, the MTA and Citi Bike's feed.
private let knownHosts: Set<String> = [WNSupport.server.host!, "api-endpoint.mta.info", "gbfs.citibikenyc.com"]

/// Privacy, bad servers, bad saves.
struct WidgetsNetworkAdversarialTests {
    // MARK: Privacy

    /// No request, answered or offline, carries a name, email, device name or custom User-Agent.
    @Test func noRequestCarriesPersonalDetails() async {
        let needles = await personalNeedles()
        let (_, answered) = await withNetwork(FeedFixtures.respond) { await driveEveryRequest() }
        let (_, offline) = await withNetwork { await driveEveryRequest() }
        let made = answered + offline
        #expect(made.count > 20)
        let found = leaks(in: made, needles: needles)
        #expect(found.isEmpty, "Personal details sent: \(found.joined(separator: "; "))")
        let hosts = Set(made.compactMap(\.url.host))
        #expect(hosts.isSubset(of: knownHosts), "Asked other hosts: \(hosts.subtracting(knownHosts))")
        // Every server request is the push server's, MTA's or Citi Bike's: over HTTPS
        #expect(made.allSatisfy { $0.url.scheme == "https" })
    }

    /// A countdown's sign-up carries the train and token, and nothing about who's asking.
    @Test func registrationBodyHasNoPersonalFields() throws {
        let registration = PushRegistration(token: "00ff", environment: "sandbox", selection: .fallback, trip: "trip")
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(registration)) as? [String: Any])
        #expect(Set(object.keys) == ["token", "environment", "selection", "trip"])
    }

    /// Diagnostics name the hardware model, never the device's own name.
    @MainActor @Test func diagnosticsNameModelNotDevice() {
        let model = Diagnostics.deviceModel
        #expect(!model.isEmpty)
        // "iPhone17,1", or the simulator's "arm64": never a name someone gave it
        #expect(model.allSatisfy { $0.isLetter || $0.isNumber || $0 == "," || $0 == "_" })
        let custom = UIDevice.current.name
        #expect(custom.contains(" ") == false || !model.contains(custom))
    }

    /// What an App Attest assertion signs: challenge, method, path and the body's hash, by lines.
    @Test func clientDataFormat() {
        let made = ClientData.make(challenge: "abc", method: "POST", path: "/diagnostics", body: Data("{}".utf8))
        let hash = CountdownLookup.hex(ClientData.hash(Data("{}".utf8)))
        #expect(String(decoding: made, as: UTF8.self) == "abc\nPOST\n/diagnostics\n\(hash)")
        #expect(hash == "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a")
    }

    #if targetEnvironment(simulator)
    /// Without App Attest (the simulator), nothing is sent to the push server's signed routes.
    @Test func pushServerWithoutAttestSendsNothing() async {
        let (_, made) = await withNetwork({ _ in .status(204) }) {
            for attempt in 0..<3 {
                do {
                    switch attempt {
                    case 0: try await PushServer.shared.sendDiagnostics(Data("{}".utf8))
                    case 1: try await PushServer.shared.unregister(token: "00ff")
                    default: try await PushServer.shared.register(PushRegistration(token: "00ff", environment: "sandbox",
                                                                                   selection: .fallback, trip: "t"))
                    }
                    Issue.record("expected unsupported")
                } catch PushServer.Failure.unsupported {
                } catch {
                    Issue.record("unexpected \(error)")
                }
            }
        }
        #expect(made.isEmpty)
    }
    #endif

    // MARK: Corrupt and odd App Group data

    /// Garbage, cut-off, empty or binary files read as nothing, without throwing.
    @Test(arguments: ["{{{", #"{"widgets":[{"id":"#, "", "null", "[1,2,3]"])
    func corruptFilesReadAsNothing(text: String) {
        let file = WNSupport.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try? Data(text.utf8).write(to: file)
        #expect(SharedStore.read(SavedWidgets.self, from: file) == nil)
        #expect(SharedStore.read(AppSettings.self, from: file) == nil)
        #expect(SharedStore.read(SharedTrip.self, from: file) == nil)
        #expect(SharedStore.read(SharedStore.SavedBoard.self, from: file) == nil)
    }

    /// A megabyte of random bytes, or a folder where the file should be, reads as nothing.
    @Test func binaryAndFolderReadAsNothing() throws {
        let file = WNSupport.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((0..<1_000_000).map { _ in UInt8.random(in: 0...255) }).write(to: file)
        #expect(SharedStore.read([String: Date].self, from: file) == nil)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        #expect(SharedStore.read([String: Date].self, from: file) == nil)
    }

    /// A corrupt file is started over by the next change, not left to fail every read.
    @Test func changeOverwritesCorruptFile() throws {
        let file = WNSupport.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{{{ not json".utf8).write(to: file)
        SharedStore.change(file, empty: [String: Date]()) { $0["w"] = Date(timeIntervalSinceReferenceDate: 0) }
        #expect(SharedStore.read([String: Date].self, from: file) == ["w": Date(timeIntervalSinceReferenceDate: 0)])
    }

    /// Without the App Group (no file), reads, writes and changes do nothing.
    @Test func missingContainerIsHarmless() {
        #expect(SharedStore.read(AppSettings.self, from: nil) == nil)
        SharedStore.write(AppSettings(), to: nil)
        var ran = false
        SharedStore.change(nil, empty: 0) { _ in ran = true }
        #expect(!ran)
    }

    /// Thousands of saved widgets round-trip and validate quickly.
    @Test func hugeSavedListRoundTrips() throws {
        let widgets = (0..<3_000).map { index in
            SavedWidget(name: "Route \(index)", selection: index.isMultiple(of: 2) ? .fallback
                : Selection(stationID: "NOPE\(index)", routes: ["R"], direction: .south), bothWays: index.isMultiple(of: 3))
        }
        let started = Date.now
        let data = try JSONEncoder().encode(SavedWidgets(widgets: widgets))
        let decoded = try JSONDecoder().decode(SavedWidgets.self, from: data)
        let validated = decoded.validated()
        #expect(Date.now.timeIntervalSince(started) < 5)
        #expect(decoded.widgets.count == 3_000)
        #expect(validated.widgets[1].selection == .fallback && validated.widgets[0].selection == .fallback)
        #expect(validated.widget(widgets[2_999].id)?.name == "Route 2999")
    }

    /// A kind from a newer version, or a bus or dock widget that lost its bus or dock, shows as a train.
    @Test(arguments: [#""kind":"ferry""#, #""kind":"bus""#, #""kind":"bike""#, #""kind":7"#, #""kind":"bus","bus":{"line":1}"#])
    func unknownKindsFallBackToSubway(kind: String) throws {
        let id = UUID()
        let json = WNSupport.json("""
        {"widgets":[{"id":"\(id.uuidString)","selection":{"stationID":"R20","routes":["R"],"direction":"N"},\(kind),"ferry":{"pier":3}}]}
        """)
        let saved = try JSONDecoder().decode(SavedWidgets.self, from: json)
        #expect(saved.widget(id)?.kind == .subway)
    }

    /// An unreadable change or plan is dropped; the widget keeps its train.
    @Test func unreadableChangeIsDropped() throws {
        let id = UUID()
        let json = WNSupport.json("""
        {"widgets":[{"id":"\(id.uuidString)","selection":{"stationID":"R20","routes":["R"],"direction":"N"},"change":{"stops":"x"},
          "commute":{"selection":{"stationID":"R14","routes":["N"],"direction":"S"},"change":[],"weekdays":[1]}}]}
        """)
        let widget = try #require(try JSONDecoder().decode(SavedWidgets.self, from: json).widget(id))
        #expect(widget.change == nil)
        #expect(widget.commute?.change == nil && widget.commute?.weekdays == [1])
    }

    /// The saved widgets' entries, as JSON objects, from `data`.
    private func entries(_ data: Data) throws -> [NSDictionary] {
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try #require(object["widgets"] as? [NSDictionary])
    }

    /// Widgets a newer version saved that this one can't read (no train, a direction it doesn't
    /// know) leave the rest readable, and are saved again as they were, in their places.
    @Test func unreadableWidgetsSurviveAndRoundTrip() throws {
        let (a, b) = (UUID(), UUID())
        let ferry = #"{"id":"F1","kind":"ferry","ferry":{"pier":11,"fare":2.75,"night":false,"note":null,"stops":["Wall St","DUMBO 🚢"]}}"#
        let east = #"{"id":"\#(UUID().uuidString)","selection":{"stationID":"R20","routes":["R"],"direction":"E"},"big":9007199254740993}"#
        let json = WNSupport.json("""
        {"widgets":[{"id":"\(a.uuidString)","selection":{"stationID":"R20","routes":["R"],"direction":"N"}},\(ferry),
                    {"id":"\(b.uuidString)","name":"Home","selection":{"stationID":"R14","routes":["N"],"direction":"S"}},\(east)]}
        """)
        let saved = try JSONDecoder().decode(SavedWidgets.self, from: json)
        #expect(saved.widgets.map { $0.id } == [a, b])
        #expect(saved.unreadable.count == 2)
        #expect(saved.validated().unreadable == saved.unreadable)

        let written = try entries(JSONEncoder().encode(saved))
        let read = try entries(json)
        #expect(written.count == 4)
        #expect(written[1] == read[1] && written[3] == read[3])
        #expect(written.map { $0["id"] as? String } == read.map { $0["id"] as? String })

        // Deleted: the one after it takes its place. Moved: they go with the one before them
        var edited = saved
        edited.delete(a)
        edited.add(SavedWidget(selection: .fallback))
        let c = edited.widgets[1].id
        edited.move(fromOffsets: [1], toOffset: 0)
        let order = try entries(JSONEncoder().encode(edited)).map { $0["id"] as? String }
        #expect(order == ["F1", c.uuidString, b.uuidString, read[3]["id"] as? String])
        // And again, from what was written
        let again = try JSONDecoder().decode(SavedWidgets.self, from: JSONEncoder().encode(edited))
        #expect(again.unreadable.map { $0.json } == saved.unreadable.map { $0.json })
    }

    /// With every widget readable, the file is written as before: widgets, then moved docks.
    @Test func readableWidgetsWriteAsBefore() throws {
        let train = SavedWidget(name: "Work", selection: .fallback)
        let dock = SavedWidget.dock(DockChoice(id: "d1", name: "5 Av & 3 St", latitude: 40.67, longitude: -73.98))
        let old = try JSONEncoder().encode(["widgets": [train, dock]])
        let saved = try JSONDecoder().decode(SavedWidgets.self, from: old)
        #expect(saved.unreadable.isEmpty)
        #expect(try entries(JSONEncoder().encode(saved)) == entries(old))
    }

    /// A direction from a newer version, or a bad id, fails that selection.
    @Test func badSelectionFieldsThrow() {
        for json in [#"{"stationID":"R20","routes":["R"],"direction":"E"}"#, #"{"routes":["R"],"direction":"N"}"#,
                     #"{"stationID":"R20","direction":"N"}"#] {
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(Selection.self, from: WNSupport.json(json)) }
        }
    }

    /// Alert kinds all from a newer version read as none, not the defaults.
    @Test func allUnknownAlertKindsReadAsNone() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: WNSupport.json(#"{"alertKinds":[7,8]}"#))
        #expect(settings.alertKinds.isEmpty)
        let missing = try JSONDecoder().decode(AppSettings.self, from: WNSupport.json(#"{"alertKinds":null}"#))
        #expect(missing.alertKinds == Set(ServiceAlert.Kind.allCases))
    }

    /// Dates after now (a clock set back) never count as fresh.
    @Test func futureDatesAreNotFresh() {
        let now = Date.now
        #expect(!now.addingTimeInterval(5).isWithin(60, before: now))
        #expect(now.addingTimeInterval(-5).isWithin(60, before: now))
        #expect(!now.isWithin(0, before: now))
    }

    /// Odd searches and bullets don't crash: empty, very long, emoji, and dozens of lines.
    @Test func oddInputsDontCrash() async throws {
        for search in ["", String(repeating: "a", count: 5_000), "🚇🚇", "%00\u{0}"] {
            #expect(try await StopQuery().entities(matching: search).count <= 60)
        }
        #expect(BulletImage.data(for: []) != nil)
        #expect(BulletImage.data(for: Array(repeating: "R", count: 30)) != nil)
        #expect(StopEntity(id: ":::") == nil && StopEntity(id: String(repeating: "R20:", count: 100)) == nil)
    }

    // MARK: Bad servers

    /// A relay answer that isn't a feed (busy, HTML, empty, cut off, redirect) has the MTA asked once.
    @Test(arguments: [0, 1, 2, 3, 4, 5])
    func badRelayAnswerFallsBackToMTA(kind: Int) async {
        let bytes = WNSupport.feedBytes
        let bad: TestNetwork.Answer = switch kind {
        case 0: .status(429)
        case 1: .status(500)
        case 2: .ok(WNSupport.json("<html><body>Cloudflare</body></html>"))
        case 3: .ok(Data())
        case 4: .ok(bytes.prefix(bytes.count / 2))
        default: TestNetwork.Answer(status: 302, headers: ["Location": "https://evil.example/feeds"],
                                    redirect: URL(string: "https://evil.example/feeds"))
        }
        let url = WNSupport.uniqueFeed()
        let (data, made) = await withNetwork({ request in WNSupport.isRelay(request.url!) ? bad : .ok(bytes) }) {
            await TrainService.optionalData(from: url)
        }
        #expect(data == bytes)
        #expect(made.count == 2)
        #expect(made.allSatisfy { knownHosts.contains($0.url.host ?? "") })
    }

    /// The push server's redirect to another host isn't followed: its 3xx is the answer.
    @Test func crossHostRedirectIsRefused() async throws {
        let evil = try #require(URL(string: "https://evil.example/steal"))
        let url = WNSupport.server.appendingPathComponent("wn-redirect")
        let (answer, made) = await withNetwork({ request in
            request.url?.host == evil.host ? .ok(WNSupport.json(#"{"ok":"evil"}"#))
                : TestNetwork.Answer(status: 302, headers: ["Location": evil.absoluteString], redirect: evil)
        }) {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.setValue("key", forHTTPHeaderField: "X-Attest-Key")
            return await ServerRoutes.fetched([String: String].self, with: request)
        }
        #expect(answer.value == nil && answer.status == 302)
        #expect(!made.contains { $0.url.host == evil.host })
        #expect(made.count == 1)
    }

    /// A redirect within the push server, over HTTPS, is followed; one down to HTTP isn't.
    @Test func sameHostRedirectIsFollowed() async throws {
        let moved = WNSupport.server.appendingPathComponent("wn-moved")
        let (answer, made) = await withNetwork({ request in
            request.url?.path == "/wn-moved" ? .ok(WNSupport.json(#"{"ok":"yes"}"#))
                : TestNetwork.Answer(status: 301, headers: ["Location": moved.absoluteString], redirect: moved)
        }) {
            await ServerRoutes.fetched([String: String].self,
                                       with: URLRequest(url: WNSupport.server.appendingPathComponent("wn-old"), timeoutInterval: 5))
        }
        #expect(answer.value == ["ok": "yes"])
        #expect(made.map(\.url.path) == ["/wn-old", "/wn-moved"])

        var plain = try #require(URLComponents(url: moved, resolvingAgainstBaseURL: false))
        plain.scheme = "http"
        let insecure = try #require(plain.url)
        let (downgraded, tried) = await withNetwork({ request in
            request.url?.scheme == "http" ? .ok(WNSupport.json(#"{"ok":"plain"}"#))
                : TestNetwork.Answer(status: 302, headers: ["Location": insecure.absoluteString], redirect: insecure)
        }) {
            await ServerRoutes.fetched([String: String].self,
                                       with: URLRequest(url: WNSupport.server.appendingPathComponent("wn-old"), timeoutInterval: 5))
        }
        #expect(downgraded.value == nil && downgraded.status == 302)
        #expect(tried.count == 1)
    }

    /// Redirects stay on HTTPS at the same host, whatever the case of its name.
    @Test func redirectRule() {
        let allows = TrainService.SameHostRedirects.allows
        #expect(allows(URL(string: "https://api.dctp.dev/a"), URL(string: "https://API.dctp.dev/b")))
        #expect(!allows(URL(string: "https://api.dctp.dev/a"), URL(string: "https://evil.example/b")))
        #expect(!allows(URL(string: "https://api.dctp.dev/a"), URL(string: "https://api.dctp.dev.evil.example/b")))
        #expect(!allows(URL(string: "https://api.dctp.dev/a"), URL(string: "http://api.dctp.dev/b")))
        #expect(!allows(nil, URL(string: "https://api.dctp.dev/b")))
    }

    /// Both answering garbage: no feed, and no more than one try each.
    @Test func bothGarbageGivesNothingOnce() async {
        let url = WNSupport.uniqueFeed()
        let (data, made) = await withNetwork({ _ in .ok(WNSupport.json("garbage")) }) {
            let data = await TrainService.optionalData(from: url)
            try? await Task.sleep(for: .seconds(1))
            return data
        }
        #expect(data == nil && made.count == 2)
    }

    /// Alerts relayed as something other than JSON have the MTA asked.
    @Test func alertsThatArentJSONFallBack() async throws {
        let alerts = try Fixtures.data("weekday1030-alerts.json")
        let (entries, made) = await withNetwork({ request in
            WNSupport.isRelay(request.url!) ? .ok(WNSupport.feedBytes) : .ok(alerts)
        }) {
            await TrainService.alertEntries(routes: ["WN\(UUID().uuidString.prefix(6))"])
        }
        #expect(entries != nil && made.count == 2)
    }

    /// /routes: over the limit says so; busy, HTML, garbage or huge answers are no routes. One try.
    @Test(arguments: [429, 500, 200, 201, 202])
    func badRoutesAnswers(kind: Int) async {
        let answer: TestNetwork.Answer = switch kind {
        case 200: .ok(WNSupport.json("<!doctype html><html></html>"))
        case 201: .ok(WNSupport.json(#"{"routes":[{"legs":[{"line":5}]}]}"#))
        case 202: .ok(Data(repeating: 0x7B, count: 5_000_000))
        default: .status(kind)
        }
        let (result, made) = await withNetwork({ _ in answer }) {
            await ServerRoutes.fetchRoutes(from: WNSupport.uniqueLocation(), to: WNSupport.uniqueLocation(),
                                           at: Date(timeIntervalSince1970: 1_950_000_000))
        }
        #expect(result.routes == nil)
        #expect(result.overLimit == (kind == 429))
        #expect(made.count == 1)
    }

    /// /docks failing falls back on Citi Bike's own feed, a bounded few requests, and gives none.
    @Test(arguments: [500, 200])
    func badDocksAnswerIsBounded(status: Int) async {
        let answer: TestNetwork.Answer = status == 200 ? .ok(WNSupport.json("<html>")) : .status(status)
        let (docks, made) = await withNetwork({ request in request.url?.path == "/docks" ? answer : nil }) {
            let docks = await CitiBike.docks(near: WNSupport.uniqueLocation())
            try? await Task.sleep(for: .seconds(0.5))
            return docks
        }
        // Nil, or none near: Citi Bike's counts kept from another fetch within a minute are reused
        #expect(docks?.isEmpty ?? true)
        #expect(made.filter { $0.url.path == "/docks" }.count == 1)
        #expect(made.count <= 3)
        #expect(made.allSatisfy { knownHosts.contains($0.url.host ?? "") })
    }

    /// The same docks asked for three times at once, as Nearby's load starts over as it finds
    /// you: one GET /docks, its answer for all three.
    @Test func docksAskedAtOnceShareOneRequest() async {
        let body = WNSupport.json(#"{"docks":[{"id":"s1","name":"4 Av & 9 St","lat":40.67,"lon":-73.99,"bikes":2,"eBikes":1,"docks":5,"renting":true,"returning":true}]}"#)
        let location = WNSupport.uniqueLocation()
        let (docks, made) = await withNetwork({ $0.url?.path == "/docks" ? .ok(body, delay: .seconds(0.3)) : nil }) {
            async let a = CitiBike.docks(near: location)
            async let b = CitiBike.docks(near: location)
            async let c = CitiBike.docks(near: location)
            return await [a, b, c]
        }
        #expect(docks.allSatisfy { $0?.map(\.id) == ["s1"] })
        #expect(made.filter { $0.url.path == "/docks" }.count == 1)
    }

    /// One that failed isn't asked again at once: neither those waiting on it nor a start over
    /// moments later (Citi Bike's own feed is still tried in its place).
    @Test func failedDocksAreNotAskedAgainAtOnce() async {
        let location = WNSupport.uniqueLocation()
        let (_, made) = await withNetwork({ $0.url?.path == "/docks" ? .status(503) : nil }) {
            async let a = CitiBike.docks(near: location)
            async let b = CitiBike.docks(near: location)
            _ = await (a, b)
            _ = await CitiBike.docks(near: location)
        }
        #expect(made.filter { $0.url.path == "/docks" }.count == 1)
    }

    /// A caller given up on (Nearby moving on) doesn't count as a failure: the next ask joins
    /// the request still under way, and has its docks.
    @Test func cancelledDocksAskIsNotAFailure() async {
        let body = WNSupport.json(#"{"docks":[{"id":"s2","name":"5 Av & 9 St","lat":40.67,"lon":-73.98,"bikes":1,"eBikes":0,"docks":3,"renting":true,"returning":true}]}"#)
        let location = WNSupport.uniqueLocation()
        let (docks, made) = await withNetwork({ $0.url?.path == "/docks" ? .ok(body, delay: .seconds(0.5)) : nil }) {
            let first = Task { await CitiBike.docks(near: location) }
            try? await Task.sleep(for: .seconds(0.1))
            first.cancel()
            return await CitiBike.docks(near: location)
        }
        #expect(docks?.map(\.id) == ["s2"])
        #expect(made.filter { $0.url.path == "/docks" }.count == 1)
    }

    /// Bus times and nearby buses that come back garbage are asked once, not retried.
    @Test func badBusAnswersAreNotRetried() async {
        let location = WNSupport.uniqueLocation()
        let place = BusRide.Place(name: "x", latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
        let (_, made) = await withNetwork({ _ in .ok(WNSupport.json("]]garbage")) }) {
            _ = await BusTimes.arrivals(line: "B63", at: place)
            _ = await NearbyBuses.places(near: location, wait: 1)
        }
        #expect(made.filter { $0.url.path == "/buses" }.count == 1)
        #expect(made.filter { $0.url.path == "/buses/nearby" }.count == 1)
    }

    /// A slow nearby-buses answer is given up on at its wait, not waited out.
    @Test func slowNearbyBusesGiveUp() async {
        let started = Date.now
        let (_, made) = await withNetwork({ _ in .ok(WNSupport.json(#"{"ways":[]}"#), delay: .seconds(8)) }) {
            _ = await NearbyBuses.places(near: WNSupport.uniqueLocation(), wait: 1)
        }
        #expect(Date.now.timeIntervalSince(started) < 6)
        #expect(made.count == 1)
    }

    /// A failed timetable download is marked, not retried for minutes but when forced, and an
    /// unreadable one isn't kept.
    @Test func failedTimetableIsNotRetriedAtOnce() async {
        let (file, name) = WNSupport.timetableFile()
        defer { WNSupport.removeTimetable(name) }
        let (_, made) = await withNetwork({ _ in .status(500) }) {
            await file.refresh()
            await file.refresh()
            await file.refresh()
        }
        #expect(made.count == 1)
        #expect(file.isDue() && file.load(now: .now) == nil)
        let (_, forced) = await withNetwork({ _ in .ok(WNSupport.json("not a timetable")) }) {
            await file.refresh(force: true)
        }
        #expect(forced.count == 1)
        #expect(file.load(now: .now) == nil)
        #expect(SharedStore.url(named: "\(name).bin").map { FileManager.default.fileExists(atPath: $0.path) } == false)
    }

    /// Offline, a board fails after a bounded few requests and makes no more after.
    @Test func offlineBoardIsBounded() async {
        // Timed to Myrtle-Wyckoff Avs, so its feed's stops are this test's own: a board's feed fetched
        // within the last 15 s by another test (the privacy test's Canarsie board) isn't reused
        let selection = Selection(stationID: "L29", routes: ["L"], direction: .north, elevatorAlerts: true)
        let destination = StationDirectory.station(id: "L17")
        let (failed, made) = await withNetwork {
            let failed = (try? await TrainService.board(for: selection, arrivingAt: destination)) == nil
            try? await Task.sleep(for: .seconds(2.5))
            return failed
        }
        #expect(failed)
        // The L's feed, alerts and outages: relay and MTA once each at most
        #expect(made.count <= 6)
        #expect(made.count >= 2)
    }

    /// Force Offline fails both sessions as with no signal, after its delay.
    @Test func forcedOfflineFailsBothSessions() async throws {
        let url = try #require(URL(string: "https://leeway-tests.invalid/offline"))
        await withNetwork {
            // Off, so Force Offline answers; the address can't resolve if it doesn't
            TestNetwork.stop()
            ForcedOffline.isOn = true
            ForcedOffline.delay = .milliseconds(300)
            defer {
                ForcedOffline.isOn = false
                ForcedOffline.delay = .zero
            }
            for session in [TrainService.serverSession, URLSession.shared] {
                let started = Date.now
                do {
                    _ = try await session.data(from: url)
                    Issue.record("expected to fail")
                } catch let error as URLError {
                    #expect(error.code == .notConnectedToInternet)
                } catch {
                    Issue.record("unexpected \(error)")
                }
                #expect(Date.now.timeIntervalSince(started) >= 0.25)
            }
        }
        #expect(!ForcedOffline.isOn)
    }

    /// The Prototyping card's switch sets Force Offline, and pausing still ends on time.
    @MainActor @Test func connectivityForceOffline() async {
        await withNetwork {
            Connectivity.shared.forceOffline(true)
            #expect(ForcedOffline.isOn)
            Connectivity.shared.forceOffline(false)
            #expect(!ForcedOffline.isOn)
            let started = Date.now
            await Connectivity.shared.pause(for: .milliseconds(100))
            #expect(Date.now.timeIntervalSince(started) < 5)
        }
    }
}

/// Tests changing the app's own defaults and files, one at a time.
@Suite(.serialized) @MainActor
struct WidgetsNetworkLocalStateTests {
    /// Runs `body` with no pending reports and Share Diagnostics set to `sharing`, then puts both back.
    private func withDiagnostics(sharing: Bool, _ body: () async throws -> Void) async rethrows {
        let manager = FileManager.default
        let pending = Diagnostics.pendingDirectory
        let aside = manager.temporaryDirectory.appending(path: "wn-pending-\(UUID().uuidString)")
        let had = manager.fileExists(atPath: pending.path)
        if had { try? manager.moveItem(at: pending, to: aside) }
        let defaults = UserDefaults.standard
        let before = defaults.object(forKey: Diagnostics.sharesKey)
        defaults.set(sharing, forKey: Diagnostics.sharesKey)
        defer {
            try? manager.removeItem(at: pending)
            if had { try? manager.moveItem(at: aside, to: pending) }
            if let before { defaults.set(before, forKey: Diagnostics.sharesKey) } else { defaults.removeObject(forKey: Diagnostics.sharesKey) }
        }
        try await body()
    }

    private func addPendingReport() throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: Diagnostics.pendingDirectory, withIntermediateDirectories: true)
        let file = Diagnostics.pendingDirectory.appending(path: "\(UUID().uuidString).json")
        try Data(#"{"kind":"crash"}"#.utf8).write(to: file)
        return file
    }

    /// With Share Diagnostics off, waiting reports are dropped and nothing is sent.
    @Test func diagnosticsNeverSentWhenSharingOff() async throws {
        try await withDiagnostics(sharing: false) {
            let report = try addPendingReport()
            let (_, made) = await withNetwork({ _ in .status(204) }) { await Diagnostics.sendPending() }
            #expect(made.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: report.path))
            #expect(!Diagnostics.isSharing)
        }
    }

    #if targetEnvironment(simulator)
    /// Shared but without App Attest, a report never leaves, and isn't kept to try forever.
    @Test func diagnosticsWithoutAttestSendNothing() async throws {
        try await withDiagnostics(sharing: true) {
            let report = try addPendingReport()
            let (_, made) = await withNetwork({ _ in .status(204) }) { await Diagnostics.sendPending() }
            #expect(made.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: report.path))
        }
    }
    #endif

    /// The log keeps whole lines, and its newest, within its limit.
    @Test func diagnosticLogKeepsWholeLines() {
        let marker = "wn-\(UUID().uuidString)"
        let line = String(repeating: "x", count: 1_000)
        for index in 0..<300 {
            DiagnosticLog.append("info", "Tests", "\(marker) \(index) \(line)")
        }
        let all = DiagnosticLog.contents()
        #expect(all.contains("\(marker) 299 "))
        #expect(all.utf8.count <= DiagnosticLog.maxBytes)
        let tail = DiagnosticLog.contents(lastBytes: 1_500)
        #expect(tail.hasPrefix("20"))
        #expect(tail.contains("\(marker) 299 "))
    }

    /// Runs `body` with `keys` cleared in the app's defaults, then puts them back.
    private func withDefaults(_ keys: [String], _ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let before = keys.map { defaults.object(forKey: $0) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in zip(keys, before) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }

    /// Recents keep the last 4 addresses, newest first, each once, never where you are.
    @Test func recentsKeepFour() {
        withDefaults(["recentPlaces"]) {
            let recents = RecentPlaces()
            let places = (0..<6).map { TripPlace(name: "Place \($0)", point: .init(latitude: 40.7 + Double($0) / 100, longitude: -73.9)) }
            places.forEach(recents.add)
            recents.add(places[3])
            recents.add(.here)
            #expect(recents.places.map(\.name) == ["Place 3", "Place 5", "Place 4", "Place 2"])
            #expect(RecentPlaces().places.map(\.name) == ["Place 3", "Place 5", "Place 4", "Place 2"])
            recents.remove(places[5])
            #expect(RecentPlaces().places.count == 3)
        }
    }

    /// Recents over a day old aren't offered, and go at the next save.
    @Test func recentsExpireAfterADay() throws {
        try withDefaults(["recentPlaces"]) {
            let old = Date.now.addingTimeInterval(-25 * 60 * 60).timeIntervalSinceReferenceDate
            let fresh = Date.now.addingTimeInterval(-60).timeIntervalSinceReferenceDate
            UserDefaults.standard.set(WNSupport.json("""
            [{"place":{"name":"Fresh","point":{"latitude":40.7,"longitude":-73.9}},"used":\(fresh)},
             {"place":{"name":"Old","point":{"latitude":40.6,"longitude":-73.9}},"used":\(old)}]
            """), forKey: "recentPlaces")
            let recents = RecentPlaces()
            #expect(recents.places.map(\.name) == ["Fresh"])
            recents.add(TripPlace(name: "New", point: .init(latitude: 40.8, longitude: -73.9)))
            let saved = try #require(UserDefaults.standard.data(forKey: "recentPlaces"))
            #expect(!String(decoding: saved, as: UTF8.self).contains("Old"))
        }
    }

    /// Corrupt recents start empty.
    @Test func corruptRecentsStartEmpty() {
        withDefaults(["recentPlaces"]) {
            UserDefaults.standard.set(Data("{{".utf8), forKey: "recentPlaces")
            #expect(RecentPlaces().places.isEmpty)
        }
    }

    /// Home, Work and added places are kept on the phone and read back; clearing forgets all.
    @Test func savedPlacesRoundTrip() {
        withDefaults(["savedPlaces", "savedPlacesAdded", "savedPlacesHomeIsHotel"]) {
            let places = SavedPlaces()
            places.set(.home, to: TripPlace(name: "123 Main St", point: .init(latitude: 40.7, longitude: -73.9)))
            let gym = places.set(.new("Gym"), to: TripPlace(name: "Gym St", point: .init(latitude: 40.6, longitude: -73.9)))
            let again = SavedPlaces()
            #expect(again.place(.home)?.detail == "123 Main St" && again.place(.home)?.name == "Home")
            #expect(again.name(gym) == "Gym" && again.slots.count == 3)
            again.clear()
            #expect(SavedPlaces().isEmpty)
        }
    }
}
