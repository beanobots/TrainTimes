import SwiftUI
import WidgetKit

/// The app's caches, each with its size and a button to clear it, and Clear All. Only what's
/// made again by itself: never Settings, saved widgets or routes, saved places, or the voice
/// pack (but its Documents copy in Xcode builds, kept out of Clear All).
struct ClearCachesTool: View {
    @State private var sizes: [CacheKind: CacheKind.Size] = [:]
    @State private var asking: CacheKind?
    @State private var askingAll = false
    @State private var done: String?
    @State private var isWalking = false

    var body: some View {
        Form {
            Section {
                ForEach(CacheKind.allCases.filter { !$0.isDevOnly }) { kind in
                    row(kind)
                }
            } footer: {
                Text("Each is made again when next needed: downloaded, drawn or routed afresh.")
            }

            #if DEBUG
            Section {
                ForEach(CacheKind.allCases.filter(\.isDevOnly)) { kind in
                    row(kind)
                }
            } header: {
                Text("Xcode Builds Only")
            } footer: {
                Text("The voice pack copied into Documents for the simulator and Xcode builds (tools/make_voice_pack.py). Not a cache: it has to be copied in again. Apple's downloaded pack isn't touched.")
            }
            #endif

            Section {
                Button("Clear All", role: .destructive) { askingAll = true }
            } footer: {
                Text(done ?? "Everything above\(isDevBuild ? " but the voice pack copy" : "")\(isWalking ? " and the Lock Screen maps, kept while walking" : "").")
            }
        }
        .task { await measure() }
        .refreshable { await measure() }
        .confirmationDialog(asking.map { "Clear \($0.title)?" } ?? "", isPresented: Binding {
            asking != nil
        } set: { if !$0 { asking = nil } }, titleVisibility: .visible, presenting: asking) { kind in
            Button("Clear", role: .destructive) {
                Task { await clear([kind]) }
            }
        } message: { kind in
            Text(kind.detail)
        }
        .confirmationDialog("Clear All Caches?", isPresented: $askingAll, titleVisibility: .visible) {
            Button("Clear All", role: .destructive) {
                Task { await clear(CacheKind.allCases.filter { !$0.isDevOnly }) }
            }
        } message: {
            Text("Timetables and alerts saved for offline go too, until they download again. Settings, widgets, routes and places stay.")
        }
    }

    private var isDevBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private func row(_ kind: CacheKind) -> some View {
        let blocked = kind == .turnMaps && isWalking
        return Button {
            asking = kind
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(kind.title).foregroundStyle(blocked ? .secondary : .primary)
                    Text(blocked ? "Kept while walking" : kind.caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(sizes[kind]?.text ?? "…")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .disabled(blocked)
    }

    private func measure() async {
        isWalking = TrainActivityController.isWalking
        for kind in CacheKind.allCases {
            sizes[kind] = await kind.size()
        }
    }

    private func clear(_ kinds: [CacheKind]) async {
        isWalking = TrainActivityController.isWalking
        var cleared: [String] = []
        for kind in kinds where !(kind == .turnMaps && isWalking) {
            await kind.clear()
            cleared.append(kind.title)
        }
        done = kinds.count == 1 ? "Cleared \(cleared.first ?? "nothing")." : "Cleared \(cleared.count) caches."
        await measure()
    }
}

/// A cache Clear Caches can clear: its files, and whatever in memory goes with them.
enum CacheKind: String, CaseIterable, Identifiable {
    case urlCache, appCaches, temporary, subwayTimetable, busTimetable, feeds, citiBike,
         widgetTimes, nearbyPlace, turnMaps, groupCaches, walkRoutes, recents, voicePackCopy

    var id: Self { self }

    /// The Documents copy of the voice pack, in Xcode builds only.
    var isDevOnly: Bool { self == .voicePackCopy }

    var title: String {
        switch self {
        case .urlCache: "URL Cache"
        case .appCaches: "App Caches Folder"
        case .temporary: "Temporary Files"
        case .subwayTimetable: "Subway Timetable"
        case .busTimetable: "Bus Timetable"
        case .feeds: "Saved Alerts and Outages"
        case .citiBike: "Citi Bike Dock Places"
        case .widgetTimes: "Widgets' Saved Times"
        case .nearbyPlace: "Nearby Widget's Place"
        case .turnMaps: "Lock Screen Turn Maps"
        case .groupCaches: "Other Shared Caches"
        case .walkRoutes: "Walk Routes"
        case .recents: "Recent Places"
        case .voicePackCopy: "Voice Pack Dev Copy"
        }
    }

    /// Under the title: where it is.
    var caption: String {
        switch self {
        case .urlCache: "URLCache.shared, on disk"
        case .appCaches: "Library/Caches: Apple Maps' tiles and more"
        case .temporary: "tmp"
        case .subwayTimetable: "App Group, timetable.bin"
        case .busTimetable: "App Group, bus-timetable.bin"
        case .feeds: "App Group, Library/Caches/Feeds"
        case .citiBike: "App Group, Library/Caches"
        case .widgetTimes: "App Group, boards, bus boards, bystanders"
        case .nearbyPlace: "App Group, place and last fix"
        case .turnMaps: "App Group, turn-map pictures"
        case .groupCaches: "App Group, rest of Library/Caches"
        case .walkRoutes: "In memory: walks and walking graph tiles"
        case .recents: "New Trip's last addresses"
        case .voicePackCopy: "Documents/VoicePack"
        }
    }

    /// In the confirmation: what clearing it does.
    var detail: String {
        switch self {
        case .urlCache: "Responses kept by URLSession's shared cache. The app's own requests mostly skip it."
        case .appCaches: "Everything in the app's Library/Caches, Apple Maps' tiles among it. The maps load slower until they're cached again."
        case .temporary: "Everything in the app's tmp folder."
        case .subwayTimetable: "Trains go untimed offline until it downloads again, at the next open or widget reload."
        case .busTimetable: "Buses go untimed offline and planning on the phone loses them until it downloads again (some 6 MB)."
        case .feeds: "Alerts and outages saved for when there's no signal. Downloaded again with the next times."
        case .citiBike: "Where the docks are, as saved. Fetched again; this run of the app keeps its own until it's closed."
        case .widgetTimes: "The times widgets last fetched, which a failed reload falls back on. Every widget reloads."
        case .nearbyPlace: "The Nearby widget's neighbourhood name and where it last found you. It looks again."
        case .turnMaps: "The pictures drawn for the Lock Screen's turns. Drawn again on the next walk."
        case .groupCaches: "Anything else in the App Group's Library/Caches."
        case .walkRoutes: "Walks routed this run, and the walking graph's tiles and routers. Routed again when asked for."
        case .recents: "The addresses New Trip lists as recent. Saved places, Home and Work stay."
        case .voicePackCopy: "Deletes Documents/VoicePack. Kokoro won't speak in this build until it's copied in again; Apple's voice speaks instead."
        }
    }

    /// Its size, or a count for what's only in memory.
    enum Size {
        case bytes(Int64)
        case items(Int)
        case none

        var text: String {
            switch self {
            case let .bytes(bytes): bytes == 0 ? "Empty" : bytes.formatted(.byteCount(style: .file))
            case let .items(count): count == 0 ? "Empty" : "\(count)"
            case .none: "—"
            }
        }
    }

    // MARK: Where

    private static var group: URL? { SharedStore.url(named: "") }

    private static func group(_ name: String) -> URL? { SharedStore.url(named: name) }

    private static let groupCachesPath = "Library/Caches"
    private static let feedsPath = "Library/Caches/Feeds"
    private static let citiBikePath = "Library/Caches/citibike-docks.json"

    /// Its files and folders: folders' contents are cleared, the folders kept.
    private var files: [URL] {
        switch self {
        case .urlCache, .walkRoutes, .recents: []
        case .appCaches: Self.contents(of: .cachesDirectory)
        case .temporary: Self.contents(of: .temporaryDirectory)
        case .subwayTimetable: [Self.group("timetable.bin"), Self.group("timetable-etag.txt")].compactMap { $0 }
        case .busTimetable: [Self.group("bus-timetable.bin"), Self.group("bus-timetable-etag.txt")].compactMap { $0 }
        case .feeds: Self.group(Self.feedsPath).map { Self.contents(of: $0) } ?? []
        case .citiBike: [Self.group(Self.citiBikePath)].compactMap { $0 }
        case .widgetTimes: ["boards.json", "bus-boards.json", "bystanders.json"].compactMap(Self.group)
        case .nearbyPlace: ["place.json", "nearby-fix.json"].compactMap(Self.group)
        case .turnMaps:
            Self.group.map { folder in
                Self.contents(of: folder).filter { $0.lastPathComponent.hasPrefix(TurnMap.prefix) }
            } ?? []
        case .groupCaches:
            Self.group(Self.groupCachesPath).map { folder in
                Self.contents(of: folder).filter { !["Feeds", "citibike-docks.json"].contains($0.lastPathComponent) }
            } ?? []
        case .voicePackCopy:
            #if DEBUG
            [VoicePack.devFolder]
            #else
            []
            #endif
        }
    }

    private static func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: Size and clearing

    @MainActor func size() async -> Size {
        switch self {
        case .urlCache: return .bytes(Int64(URLCache.shared.currentDiskUsage))
        case .walkRoutes: return .items(await WalkingDirections.cachedCount())
        case .recents: return .items(RecentPlaces.shared.places.count)
        default:
            let files = files
            return .bytes(await Task.detached(priority: .utility) { files.reduce(0) { $0 + Self.bytes(at: $1) } }.value)
        }
    }

    /// Bytes on disk at `url`, a file or everything in a folder.
    private nonisolated static func bytes(at url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isDirectoryKey]
        func size(_ url: URL) -> Int64 {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
            return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return size(url) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker { total += size(file) }
        return total
    }

    @MainActor func clear() async {
        switch self {
        case .urlCache:
            URLCache.shared.removeAllCachedResponses()
        case .appCaches:
            // The URL cache's own files are in here: let it go first
            URLCache.shared.removeAllCachedResponses()
            remove(files)
        case .walkRoutes:
            await WalkingDirections.clearCache()
            await WalkGraphStore.shared.drop()
            await WalkGraphStore.long.drop()
        case .recents:
            for place in RecentPlaces.shared.places { RecentPlaces.shared.remove(place) }
        case .widgetTimes:
            Bystanders.clear()
            remove(files)
            WidgetCenter.shared.reloadAllTimelines()
        case .turnMaps:
            TurnMap.clear()
        default:
            remove(files)
        }
        AppLog(category: "Prototyping").notice("Cleared \(title)")
    }

    private func remove(_ files: [URL]) {
        for file in files { try? FileManager.default.removeItem(at: file) }
    }
}

#Preview {
    NavigationStack { ClearCachesTool() }
}
