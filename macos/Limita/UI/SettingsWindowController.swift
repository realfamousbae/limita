import AppKit
import SwiftUI

/// The tabs of the Settings window.
enum SettingsTab: String, CaseIterable, Identifiable, Sendable {
    case general
    case providers
    case shortcuts
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .shortcuts: "Shortcuts"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .providers: "square.stack.3d.up"
        case .shortcuts: "keyboard"
        case .updates: "arrow.down.circle"
        }
    }
}

/// Which tab the Settings window shows; shared with the view so `show(tab:)` can switch it.
@Observable
@MainActor
final class SettingsNavigation {
    var tab: SettingsTab = .general
}

/// The Settings window: one copy, opened from the menu, the dashboard's gear button or
/// the connect prompt. An accessory app has no Dock icon, so the window is brought to
/// the front explicitly.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: LimitsStore
    private let hotKeys: HotKeyCenter
    private let navigation = SettingsNavigation()
    private var window: NSWindow?

    init(store: LimitsStore, hotKeys: HotKeyCenter) {
        self.store = store
        self.hotKeys = hotKeys
    }

    /// Shows the window, on `tab` when given, or where it was left.
    func show(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        let opening = !window.isVisible
        if opening { window.center() }
        window.makeKeyAndOrderFront(nil)
        // No field takes the keyboard by itself: typing goes nowhere until one is clicked.
        if opening { window.makeFirstResponder(nil) }
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(store: store, hotKeys: hotKeys, navigation: navigation)
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Limita Settings"
        window.contentViewController = NSHostingController(rootView: view)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("LimitaSettings")
        return window
    }

    func windowWillClose(_ notification: Notification) {
        // A shortcut being recorded must not stay suspended once the window is gone.
        hotKeys.suspend(false)
    }
}

/// An accessory app has no menu bar, so the usual ⌘ shortcuts of text fields (paste the
/// API key) and of windows (close) are handled here.
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift], let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        let action: Selector? = switch (key, flags.contains(.shift)) {
        case ("x", false): #selector(NSText.cut(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        if key == "w", !flags.contains(.shift) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
