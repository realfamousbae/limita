import AppKit
import SwiftUI

/// JetBrains Mono Nerd Font Mono, bundled in `Resources/Fonts` and registered through
/// `ATSApplicationFontsPath` in Info.plist. Only the Regular face ships, so hierarchy
/// comes from size and opacity rather than weight.
enum AppFont {
    static let name = "JetBrainsMonoNFM-Regular"

    static func ns(_ size: CGFloat) -> NSFont {
        NSFont(name: name, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension Font {
    /// Falls back to the system font where the bundle is absent (e.g. `swift test`).
    static func app(_ size: CGFloat) -> Font {
        .custom(AppFont.name, fixedSize: size)
    }
}
