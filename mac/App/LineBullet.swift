import SwiftUI

/// A line's round bullet on the MTA's colour for it, as the iOS app draws it.
struct LineBullet: View {
    /// A real-time route id such as "R", "FS" or "SI".
    let route: String
    var size: CGFloat = 16

    var body: some View {
        let (label, color, darkText) = Self.style(of: route)
        Text(label)
            .font(.system(size: size * (label.count > 1 ? 0.45 : 0.62), weight: .bold))
            .foregroundStyle(darkText ? .black : .white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
            .accessibilityLabel("\(route) train")
    }

    /// The bullet's label, colour, and whether it takes black text; from the server's LineStyle.
    private static func style(of route: String) -> (String, Color, Bool) {
        switch route {
        case "1", "2", "3": (route, Color(hex: 0xEE352E), false)
        case "4", "5", "6": (route, Color(hex: 0x00933C), false)
        case "7": (route, Color(hex: 0xB933AD), false)
        case "A", "C", "E": (route, Color(hex: 0x0039A6), false)
        case "B", "D", "F", "M": (route, Color(hex: 0xFF6319), false)
        case "G": (route, Color(hex: 0x6CBE45), true)
        case "J", "Z": (route, Color(hex: 0x996633), false)
        case "L": (route, Color(hex: 0xA7A9AC), true)
        case "N", "Q", "R", "W": (route, Color(hex: 0xFCCC0A), true)
        case "GS", "FS", "H": ("S", Color(hex: 0x808183), false)
        case "SI": ("SI", Color(hex: 0x0078C6), false)
        default: (route, Color(hex: 0x808183), false)
        }
    }
}

private extension Color {
    /// 0xRRGGBB
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}
