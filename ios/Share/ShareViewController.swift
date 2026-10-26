import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Share sheet's Leeway action: hosts `ShareView` and ends the request when it's done.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        let model = ShareModel(attachments: items.flatMap { $0.attachments ?? [] })
        let host = UIHostingController(rootView: ShareView(model: model) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        })
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }
}

extension NSItemProvider: @retroactive @unchecked Sendable {}

/// What was shared, as links: shared URLs, and any in shared text (Google Maps shares
/// "Directions from … https://maps.app.goo.gl/…").
func sharedLinks(in attachments: [NSItemProvider]) async -> [URL] {
    var links: [URL] = []
    for provider in attachments {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
            links.append(url)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                  let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            links += urls(in: text)
        }
    }
    return links
}

/// The links in `text`.
func urls(in text: String) -> [URL] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
    return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
}
