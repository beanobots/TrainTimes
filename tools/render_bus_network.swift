// Draws `make_bus_network.py debug` GeoJSON as PNGs, to look over where each bus line's
// each way is drawn: the city's street centrelines grey, direction 0 of each line blue and
// direction 1 red (so a two-way street shows a blue and a red lane on opposite kerbs), its
// stops as black dots with a tick the way their buses go.
//
//     swift tools/render_bus_network.swift debug_dir out_dir
import AppKit
import CoreGraphics
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: swift render_bus_network.swift debug_dir out_dir")
    exit(1)
}
let input = URL(fileURLWithPath: arguments[1]), output = URL(fileURLWithPath: arguments[2])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Pixels per metre, and the image's width at most.
let scale = Double(ProcessInfo.processInfo.environment["SCALE"] ?? "1.6") ?? 1.6, widest = 3200.0

for file in (try FileManager.default.contentsOfDirectory(at: input, includingPropertiesForKeys: nil))
    .filter({ $0.pathExtension == "geojson" }).sorted(by: { $0.path < $1.path }) {
    guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any],
          let box = json["bbox"] as? [Double], let features = json["features"] as? [[String: Any]] else { continue }
    let (west, south, east, north) = (box[0], box[1], box[2], box[3])
    let metresEast = 111_320 * cos((south + north) / 2 * .pi / 180)
    let k = min(scale, widest / ((east - west) * metresEast))
    let width = Int((east - west) * metresEast * k), height = Int((north - south) * 110_540 * k)
    func point(_ c: [Double]) -> CGPoint {
        CGPoint(x: (c[0] - west) * metresEast * k, y: (c[1] - south) * 110_540 * k)
    }
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setLineCap(.round)
    context.setLineJoin(.round)

    func stroke(_ coordinates: [[Double]], color: CGColor, width: CGFloat) {
        guard let first = coordinates.first else { return }
        context.beginPath()
        context.move(to: point(first))
        for c in coordinates.dropFirst() { context.addLine(to: point(c)) }
        context.setStrokeColor(color)
        context.setLineWidth(width)
        context.strokePath()
    }

    // Streets first, then ways, then stops over them
    for kind in ["street", "way", "stop"] {
        for feature in features {
            guard let props = feature["properties"] as? [String: Any], props["kind"] as? String == kind,
                  let geometry = feature["geometry"] as? [String: Any] else { continue }
            switch kind {
            case "street":
                if let coordinates = geometry["coordinates"] as? [[Double]] {
                    stroke(coordinates, color: CGColor(gray: 0.78, alpha: 1), width: 1)
                }
            case "way":
                if let coordinates = geometry["coordinates"] as? [[Double]] {
                    let direction = props["direction"] as? Int ?? 0
                    let color = direction == 0 ? CGColor(red: 0.1, green: 0.35, blue: 0.9, alpha: 0.75)
                        : CGColor(red: 0.9, green: 0.15, blue: 0.15, alpha: 0.75)
                    stroke(coordinates, color: color, width: 2)
                }
            default:
                if let c = geometry["coordinates"] as? [Double] {
                    let p = point(c)
                    let bearing = (props["bearing"] as? Double ?? 0) * .pi / 180
                    context.setFillColor(CGColor(gray: 0, alpha: 1))
                    context.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                    context.beginPath()
                    context.move(to: p)
                    context.addLine(to: CGPoint(x: p.x + sin(bearing) * 9, y: p.y + cos(bearing) * 9))
                    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
                    context.setLineWidth(1.5)
                    context.strokePath()
                }
            }
        }
    }
    guard let image = context.makeImage() else { continue }
    let target = output.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".png")
    let rep = NSBitmapImageRep(cgImage: image)
    try rep.representation(using: .png, properties: [:])?.write(to: target)
    print("\(target.lastPathComponent): \(width)×\(height)")
}
