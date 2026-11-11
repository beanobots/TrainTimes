import BackgroundAssets
import Foundation

/// The walking voice's files (tools/make_voice_pack.py): Kokoro's model, its voice, and the
/// words, in an asset pack Apple hosts. It downloads as Leeway installs, finishing in the
/// background (its manifest's prefetch policy, `VoicePackDownloader`), so a first walk mostly
/// has it; until then, Apple's voice speaks (`WalkVoice`).
enum VoicePack {
    static let id = "VoicePack"
    /// The pack's been asked for this launch, and not failed over a minute ago.
    @MainActor private static var asked = false
    static let log = AppLog(category: "VoicePack")

    /// Where the pack's files are, once it's downloaded; nil until then.
    static func folder() -> URL? {
        #if DEBUG
        // The simulator and Xcode builds can't reach Apple's asset packs: the files copied into
        // Documents/VoicePack instead (tools/make_voice_pack.py)
        if FileManager.default.fileExists(atPath: devFolder.appending(path: "kokoro.onnx").path) {
            return devFolder
        }
        #endif
        // Its model where the pack puts it (`assetPackIsAvailableLocally` is iOS 26.4's)
        guard let model = try? AssetPackManager.shared.url(for: "kokoro.onnx"),
              FileManager.default.fileExists(atPath: model.path) else { return nil }
        return model.deletingLastPathComponent()
    }

    #if DEBUG
    static var devFolder: URL {
        URL.documentsDirectory.appending(path: "VoicePack", directoryHint: .isDirectory)
    }
    #endif

    /// Makes sure the pack's on the phone, as speaking directions is on: it's fetched as Leeway
    /// installs, but a dropped connection then can leave it until it's asked for again.
    @MainActor static func ensure() {
        // Once a launch: each sentence would ask again while it's missing
        guard folder() == nil, !asked else { return }
        asked = true
        Task.detached(priority: .background) {
            do {
                let pack = try await AssetPackManager.shared.assetPack(withID: id)
                try await AssetPackManager.shared.ensureLocalAvailability(of: pack)
                log.info("Voice pack ready")
                await MainActor.run { WalkVoice.shared.packArrived() }
            } catch {
                log.notice("Voice pack not ready: \(error.localizedDescription)")
                // Asked again after a minute, not before
                try? await Task.sleep(for: .seconds(60))
                await MainActor.run { asked = false }
            }
        }
    }
}

/// How the voice pack's download is going, for setup to show under Speak Directions: iOS's
/// own updates while it downloads.
@MainActor
@Observable
final class VoicePackProgress {
    enum State: Hashable {
        /// Not asked yet.
        case checking
        /// On the phone: Kokoro speaks.
        case ready
        /// Coming in, this far (0–1).
        case downloading(Double)
        /// Not started, paused or failed: it comes later, in the background.
        case waiting
    }

    private(set) var state: State
    /// Fixed, for previews: not watched.
    private let fixed: Bool

    init(state: State? = nil) {
        self.state = state ?? .checking
        fixed = state != nil
    }

    /// Follows the download until it's on the phone or this is cancelled (the page left).
    func watch() async {
        guard !fixed else { return }
        if VoicePack.folder() != nil {
            state = .ready
            return
        }
        state = .waiting
        VoicePack.ensure()
        for await update in AssetPackManager.shared.statusUpdates(forAssetPackWithID: VoicePack.id) {
            switch update {
            case .began: state = .downloading(0)
            case .downloading(_, let progress): state = .downloading(progress.fractionCompleted)
            case .finished: state = .ready
            case .paused, .failed: state = .waiting
            @unknown default: break
            }
        }
        if VoicePack.folder() != nil { state = .ready }
    }
}
