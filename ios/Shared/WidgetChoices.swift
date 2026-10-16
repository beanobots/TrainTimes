import UIKit

/// Line bullets as a picture, for the Edit menu's lists, which take an image
/// rather than a view: one, or several in about the room of one, as
/// `LineBullets` draws them.
enum BulletImage {
    private static let cache = NSCache<NSString, NSData>()

    static func data(for routes: [String]) -> Data? {
        let key = routes.joined(separator: ",") as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let side: CGFloat = 60
        let gap: CGFloat = 3
        let count = routes.count
        let columns = count == 1 ? 1 : count <= 4 ? 2 : 3
        let rows = (count + columns - 1) / columns
        let across = CGFloat(max(columns, rows))
        let size = (side - gap * (across - 1)) / across
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let top = (side - CGFloat(rows) * size - CGFloat(rows - 1) * gap) / 2
            for (index, route) in routes.enumerated() {
                let style = LineStyle.of(route)
                let row = index / columns
                let inRow = CGFloat(min(columns, count - row * columns))
                let left = (side - inRow * size - (inRow - 1) * gap) / 2
                let circle = CGRect(x: left + CGFloat(index % columns) * (size + gap), y: top + CGFloat(row) * (size + gap), width: size, height: size)
                UIColor(
                    red: CGFloat((style.color >> 16) & 0xFF) / 255,
                    green: CGFloat((style.color >> 8) & 0xFF) / 255,
                    blue: CGFloat(style.color & 0xFF) / 255,
                    alpha: 1
                ).setFill()
                UIBezierPath(ovalIn: circle).fill()
                let font = UIFont.systemFont(ofSize: size * (style.label.count > 1 ? 0.45 : 0.62), weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: style.usesDarkText ? UIColor.black : UIColor.white,
                ]
                let label = style.label as NSString
                let width = label.size(withAttributes: attributes).width
                // Centred on its capitals, as LineBullet is
                label.draw(at: CGPoint(x: circle.midX - width / 2, y: circle.midY + font.capHeight / 2 - font.ascender), withAttributes: attributes)
            }
        }
        guard let png = image.pngData() else { return nil }
        cache.setObject(png as NSData, forKey: key)
        return png
    }
}
