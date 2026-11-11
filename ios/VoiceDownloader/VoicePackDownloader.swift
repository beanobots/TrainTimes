import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Downloads the walking voice's asset pack (`VoicePack`) as Leeway installs and updates, when
/// the app isn't running: the system's own downloader for Apple-hosted packs, by each pack's
/// download policy (prefetch, for the voice).
@main
struct VoicePackDownloader: StoreDownloaderExtension {}
