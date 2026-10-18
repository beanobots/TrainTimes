import UIKit

/// The app's icon is the bullet of the default widget's line (its first, with
/// more than one). The R's is the main icon; every other bullet's is an
/// alternate one in the asset catalog, drawn by tools/make_app_icons.py.
enum AppIcon {
    /// The alternate icon with `route`'s bullet, or nil for the R's: "AppIcon-7",
    /// "AppIcon-S" for the three shuttles.
    static func name(for route: String) -> String? {
        let label = LineStyle.of(route).label
        return label == "R" ? nil : "AppIcon-\(label)"
    }

    /// The bullets there's an icon for: one per line, and one S for the shuttles.
    private static let labels = Set(Lines.filterRoutes.map { LineStyle.of($0).label })

    /// Changes the icon to `route`'s bullet. iOS only lets the app do this while
    /// it's in front, and says so in an alert.
    @MainActor static func show(_ route: String) {
        let app = UIApplication.shared
        let name = name(for: route)
        guard labels.contains(LineStyle.of(route).label), app.supportsAlternateIcons,
              app.alternateIconName != name else { return }
        // If it fails, the next time the app opens tries again
        app.setAlternateIconName(name, completionHandler: nil)
    }
}
