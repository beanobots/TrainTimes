import UIKit

/// Line bullets as a PNG for Edit menu lists, which take images, not views. Laid out like
/// `LineBullets`.
enum BulletImage {
    private static let cache = NSCache<NSString, NSData>()
    private static let side: CGFloat = 60
    private static let scale: CGFloat = 3
    /// Image width in pixels, for drawing at another size.
    static let pixelSide = side * scale

    static func data(for routes: [String]) -> Data? {
        let key = routes.joined(separator: ",") as NSString
        if let cached = cache.object(forKey: key) { return cached as Data }
        let gap: CGFloat = 3
        let count = routes.count
        let (columns, rows, size) = LineBullets.grid(count: count, side: side, gap: gap)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            let top = (side - CGFloat(rows) * size - CGFloat(rows - 1) * gap) / 2
            for (index, route) in routes.enumerated() {
                // An express run of a line ("6X") is its line's bullet as a diamond, as the MTA draws it
                let line = Lines.normalized(route)
                let isExpress = line != route && route.hasSuffix("X")
                let style = LineStyle.of(line)
                let row = index / columns
                let inRow = CGFloat(min(columns, count - row * columns))
                let left = (side - inRow * size - (inRow - 1) * gap) / 2
                let circle = CGRect(x: left + CGFloat(index % columns) * (size + gap), y: top + CGFloat(row) * (size + gap), width: size, height: size)
                style.uiColor.setFill()
                if isExpress {
                    let diamond = UIBezierPath()
                    diamond.move(to: CGPoint(x: circle.midX, y: circle.minY))
                    diamond.addLine(to: CGPoint(x: circle.maxX, y: circle.midY))
                    diamond.addLine(to: CGPoint(x: circle.midX, y: circle.maxY))
                    diamond.addLine(to: CGPoint(x: circle.minX, y: circle.midY))
                    diamond.close()
                    diamond.fill()
                } else {
                    UIBezierPath(ovalIn: circle).fill()
                }
                // A diamond has less room inside than a circle
                let font = UIFont.systemFont(ofSize: style.labelSize(bullet: size) * (isExpress ? 0.8 : 1), weight: .bold)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: style.textUIColor,
                ]
                let label = style.label as NSString
                let width = label.size(withAttributes: attributes).width
                // Centre the line box, then offset as LineBullet does to centre the capitals
                let lineTop = circle.midY - (font.ascender - font.descender) / 2
                    - LineBullet.capitalsOffset(fontSize: font.pointSize)
                label.draw(at: CGPoint(x: circle.midX - width / 2, y: lineTop), withAttributes: attributes)
            }
        }
        guard let png = image.pngData() else { return nil }
        cache.setObject(png as NSData, forKey: key)
        return png
    }
}
