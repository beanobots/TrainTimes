// Draws `make_walk_graph.py debug` and `graph-debug` GeoJSON as PNGs, to look over how
// the walking graph reads a place: streets dark grey, paths green, highways and ramps
// red, OSM paths purple, parks pale green, junctions as dots (orange off grade). Built
// graphs add each street's sidewalk lines (blue; orange dashed at the curb where there's
// no sidewalk), median links (thick blue), corners (green on a sidewalk, red off one,
// blue in a median, grey on a path) and signals (yellow rings).
//
//     swift tools/render_walk_debug.swift debug_dir out_dir
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift render_walk_debug.swift debug_dir out_dir")
    exit(1)
}
let input = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Pixels per metre, and the image's width at most.
let scale = 2.2, widest = 2400.0

for file in (try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil))
    .filter({ $0.pathExtension == "geojson" }).sorted(by: { $0.path < $1.path }) {
    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
          let box = json["bbox"] as? [Double], let features = json["features"] as? [[String: Any]] else { continue }
    let (west, south, east, north) = (box[0], box[1], box[2], box[3])
    let metresEast = 111_320 * cos((south + north) / 2 * .pi / 180)
    let k = min(scale, widest / ((east - west) * metresEast))
    let width = Int((east - west) * metresEast * k), height = Int((north - south) * 111_320 * k)
    func point(_ c: [Double]) -> CGPoint {
        CGPoint(x: (c[0] - west) * metresEast * k, y: (c[1] - south) * 111_320 * k)
    }
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    func kind(_ f: [String: Any]) -> String { (f["properties"] as? [String: Any])?["kind"] as? String ?? "" }
    func coordinates(_ f: [String: Any]) -> Any? { (f["geometry"] as? [String: Any])?["coordinates"] }
    func stroke(_ line: [[Double]], _ color: CGColor, _ lineWidth: CGFloat, dash: [CGFloat] = []) {
        guard line.count > 1 else { return }
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineDash(phase: 0, lengths: dash)
        context.addLines(between: line.map(point))
        context.strokePath()
    }

    // Parks, then lines by how they're read, then junctions, then names
    for f in features where kind(f) == "park" {
        guard let rings = coordinates(f) as? [[[Double]]], let ring = rings.first, ring.count > 2 else { continue }
        context.setFillColor(CGColor(red: 0.85, green: 0.94, blue: 0.82, alpha: 1))
        context.addLines(between: ring.map(point))
        context.closePath()
        context.fillPath()
    }
    let styles: [(String, CGColor, CGFloat, [CGFloat])] = [
        ("drop", CGColor(gray: 0.8, alpha: 1), 1, [4, 4]),
        ("osm", CGColor(red: 0.55, green: 0.2, blue: 0.75, alpha: 0.8), 2, [5, 3]),
        ("walk", CGColor(gray: 0.3, alpha: 1), 3, []),
        ("path", CGColor(red: 0.1, green: 0.6, blue: 0.2, alpha: 1), 3, []),
        ("arm", CGColor(red: 0.85, green: 0.15, blue: 0.1, alpha: 0.9), 3, []),
        ("median", CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 1), 5, []),
        ("side", CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 0.8), 1.5, []),
        ("side-none", CGColor(red: 1, green: 0.5, blue: 0, alpha: 0.9), 1.5, [4, 3]),
        // OpenStreetMap's sidewalks and crosswalks over the city's streets (thin grey)
        ("cscl-walk", CGColor(gray: 0.55, alpha: 0.8), 1, []),
        ("cscl-arm", CGColor(red: 0.9, green: 0.4, blue: 0.4, alpha: 0.7), 1, []),
        ("cscl-path", CGColor(red: 0.3, green: 0.7, blue: 0.3, alpha: 0.7), 1, []),
        ("osm-sidewalk", CGColor(red: 0.15, green: 0.4, blue: 0.95, alpha: 0.9), 3, []),
        ("osm-island", CGColor(red: 0.5, green: 0.2, blue: 0.8, alpha: 0.9), 3, []),
        ("osm-crossing", CGColor(red: 0.95, green: 0.2, blue: 0.1, alpha: 1), 4, []),
        ("osm-crossing-signal", CGColor(red: 0.05, green: 0.7, blue: 0.2, alpha: 1), 4, []),
    ]
    for (name, color, lineWidth, dash) in styles {
        for f in features where kind(f) == name {
            if let line = coordinates(f) as? [[Double]] { stroke(line, color, lineWidth, dash: dash) }
        }
    }
    context.setLineDash(phase: 0, lengths: [])
    for f in features where kind(f) == "junction" {
        guard let c = coordinates(f) as? [Double], let p = f["properties"] as? [String: Any] else { continue }
        let level = p["level"] as? Int ?? 13, degree = p["degree"] as? Int ?? 0
        let r: CGFloat = degree == 1 ? 4 : 2.5
        context.setFillColor(level == 13 ? (degree == 1 ? CGColor(red: 0, green: 0.3, blue: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
                             : CGColor(red: 1, green: 0.55, blue: 0, alpha: 1))
        let at = point(c)
        context.fillEllipse(in: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
    }
    // Corners and signals
    let marks: [String: (CGColor, CGFloat)] = [
        "corner-sidewalk": (CGColor(red: 0.1, green: 0.7, blue: 0.2, alpha: 1), 3.5),
        "corner-none": (CGColor(red: 0.95, green: 0.1, blue: 0.1, alpha: 1), 4.5),
        "corner-refuge": (CGColor(red: 0.1, green: 0.3, blue: 1, alpha: 1), 4.5),
        "corner-path": (CGColor(gray: 0.55, alpha: 1), 2.5),
    ]
    for f in features {
        guard let c = coordinates(f) as? [Double] else { continue }
        let at = point(c)
        if let (color, r) = marks[kind(f)] {
            context.setFillColor(color)
            context.fillEllipse(in: CGRect(x: at.x - r, y: at.y - r, width: r * 2, height: r * 2))
        } else if kind(f) == "signal" {
            context.setStrokeColor(CGColor(red: 0.95, green: 0.75, blue: 0, alpha: 1))
            context.setLineWidth(2.5)
            context.strokeEllipse(in: CGRect(x: at.x - 9, y: at.y - 9, width: 18, height: 18))
        }
    }
    // Each street's name once, at the middle of its longest block here
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.current = graphics
    var longest: [String: ([[Double]], Double)] = [:]
    for f in features where ["walk", "path", "arm"].contains(kind(f)) {
        guard let line = coordinates(f) as? [[Double]], let name = (f["properties"] as? [String: Any])?["name"] as? String else { continue }
        let span = hypot((line.last![0] - line[0][0]) * metresEast, (line.last![1] - line[0][1]) * 111_320)
        if span > (longest[name]?.1 ?? 0) { longest[name] = (line, span) }
    }
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                     .foregroundColor: NSColor.black,
                                                     .backgroundColor: NSColor.white.withAlphaComponent(0.7)]
    for (name, (line, _)) in longest {
        let middle = point(line[line.count / 2])
        NSAttributedString(string: name, attributes: attributes).draw(at: CGPoint(x: middle.x + 4, y: middle.y + 2))
    }
    NSGraphicsContext.current = nil

    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    let target = output.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".png")
    try image.representation(using: .png, properties: [:])!.write(to: target)
    print(target.path, width, "x", height)
}
