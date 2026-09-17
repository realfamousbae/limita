import SwiftUI

@main
struct LimitaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We don't use a WindowGroup — the app lives in the menu bar + bezel panel only.
        // Settings scene for keyboard shortcut Cmd+, (optional)
        Settings {
            EmptyView()
        }
    }
}
