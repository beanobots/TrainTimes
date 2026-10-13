import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// A live prediction, on the widget's black background.
    static let liveGreen = Color(red: 0.30, green: 0.85, blue: 0.39)
}

/// A line's round bullet: its letter or number on the MTA's color for it.
struct LineBullet: View {
    /// A real-time route id; see `LineStyle.of`.
    let route: String
    let size: CGFloat

    var body: some View {
        let style = LineStyle.of(route)
        Text(style.label)
            .font(.system(size: size * (style.label.count > 1 ? 0.45 : 0.62), weight: .bold))
            .foregroundStyle(style.usesDarkText ? Color.black : Color.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Color(hex: style.color)))
            .accessibilityLabel("\(style.label) train")
    }
}
