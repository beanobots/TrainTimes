import SwiftUI
import UIKit

/// The home screen widgets' sizes. A medium widget 158 points tall or more (an
/// iPhone 12's or later's, apart from the minis) has larger text; the small
/// widget, and the medium one on an SE or a mini, are compact.
struct BoardStyle {
    let isLarge: Bool

    static let compact = BoardStyle(isLarge: false)
    static let large = BoardStyle(isLarge: true)

    // The station and direction across the top

    var bulletSize: CGFloat { isLarge ? 30 : 26 }
    var headerSpacing: CGFloat { isLarge ? 8 : 7 }
    var nameFont: Font { isLarge ? .body.bold() : .subheadline.bold() }
    var nameUIFont: UIFont { .systemFont(ofSize: Self.points(isLarge ? .body : .subheadline), weight: .bold) }
    /// The station shrinks this far before it's cut short.
    var nameScale: CGFloat { isLarge ? 0.82 : 0.85 }
    var headingFont: Font { isLarge ? .footnote : .caption2 }
    var headingUIFont: UIFont { .preferredFont(forTextStyle: isLarge ? .footnote : .caption2) }
    var headingScale: CGFloat { isLarge ? 0.85 : 0.8 }

    // The countdown

    var countdownSize: CGFloat { isLarge ? 48 : 32 }
    var countdownHeight: CGFloat { isLarge ? 36 : 34 }
    var countdownBullet: CGFloat { isLarge ? 24 : 18 }

    // The column on the right: the later trains, or the stops before yours

    var columnWidth: CGFloat { isLarge ? 150 : 130 }
    /// Between the column and what's to its left.
    var columnGap: CGFloat { 10 }
    var rowHeight: CGFloat { isLarge ? 19 : 14.5 }

    /// How many rows the column has room for, from the top beside the station.
    var columnRows: Int { isLarge ? 4 : 5 }

    var timeFont: Font { isLarge ? .body.weight(.semibold) : .footnote.weight(.semibold) }
    var timeUIFont: UIFont { .monospacedDigitSystemFont(ofSize: Self.points(isLarge ? .body : .footnote), weight: .semibold) }
    var minutesFont: Font { isLarge ? .subheadline.weight(.medium) : .caption.weight(.medium) }
    var minutesUIFont: UIFont { .monospacedDigitSystemFont(ofSize: Self.points(isLarge ? .subheadline : .caption1), weight: .medium) }
    var timeBullet: CGFloat { isLarge ? 16 : 13 }
    /// Between a later train's time and its minutes to go.
    var minutesGap: CGFloat { isLarge ? 12 : 10 }

    var stopFont: Font { isLarge ? .subheadline : .caption }
    var departsFont: Font { isLarge ? .footnote.weight(.semibold) : .caption.weight(.semibold) }
    var railColumn: CGFloat { isLarge ? 18 : 16 }
    var markerSize: CGFloat { isLarge ? 18 : 15 }
    var dotSize: CGFloat { isLarge ? 10 : 8 }
    var ringSize: CGFloat { isLarge ? 16 : 13 }

    // ↻, map and walk

    var buttonHeight: CGFloat { isLarge ? 26 : 24 }

    private static func points(_ style: UIFont.TextStyle) -> CGFloat {
        UIFont.preferredFont(forTextStyle: style).pointSize
    }
}

extension String {
    /// How wide this is on one line in `font`.
    func width(in font: UIFont) -> CGFloat {
        ceil((self as NSString).size(withAttributes: [.font: font]).width)
    }
}
