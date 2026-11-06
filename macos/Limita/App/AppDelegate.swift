import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = LimitsStore()
    private var panelController: BezelPanelController?
    private var statusItem: NSStatusItem?
    private let hotKeys = HotKeyCenter()
    private var settingsController: SettingsWindowController?
    private var showLimitsMenuItem: NSMenuItem?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store.repairClaudeHookIfNeeded()
        store.startAutoRefresh()
        store.updater.start()
        SystemResetNotifier.shared.activate { [weak self] in
            self?.panelController?.showAtTopOfCursorScreen()
        }
        store.resets.start()

        panelController = BezelPanelController(store: store)
        settingsController = SettingsWindowController(store: store, hotKeys: hotKeys)
        store.onOpenSettings = { [weak self] tab in
            self?.openSettings(tab: tab)
        }
        store.onHoverEnabledChange = { [weak self] enabled in
            self?.panelController?.setHoverEnabled(enabled)
        }
        store.onFloatingChange = { [weak self] enabled in
            self?.panelController?.setFloating(enabled)
        }
        hotKeys.onChange = { [weak self] in
            self?.updateShowLimitsHint()
        }
        hotKeys.start([
            .dashboard: { [weak self] in self?.panelController?.toggleFromShortcut() },
            .hoverPill: { [weak self] in self?.store.hoverEnabled.toggle() },
            .floatingWindow: { [weak self] in self?.store.floatingEnabled.toggle() },
        ])
        setupStatusItem()

        // Opened by hand (Launchpad, Finder, Spotlight, or after an update): show the
        // dashboard, so a fresh start is never just an icon in the menu bar. Started by
        // the system at login: stay out of the way, unless the dashboard is pinned as a
        // floating window, which is meant to be always there.
        if CommandLine.arguments.contains("--show") || !launchedAsLoginItem || store.floatingEnabled {
            // The status item is positioned on the next layout pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showLimits()
            }
        }
    }

    /// Captured before launch finishes, while the launch event is still current.
    private var launchedAsLoginItem = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        launchedAsLoginItem = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opening Limita again while it runs (Launchpad, Finder, Dock) shows the dashboard.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLimits()
        return false
    }

    /// `limita://dashboard`, opened by the iTerm2 status-bar component, and
    /// `limita://settings` or `limita://settings/providers` for a Settings tab.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "limita" {
            switch url.host {
            case "dashboard":
                panelController?.showAtTopOfCursorScreen()
            case "settings":
                openSettings(tab: SettingsTab(rawValue: url.lastPathComponent))
            default:
                continue
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        TerminalSnapshot.remove()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: "StatusIcon")
                ?? NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Limita")
            image?.isTemplate = true
            image?.size = NSSize(width: 18, height: 18)
            image?.accessibilityDescription = "Limita"
            button.image = image
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        // macOS remembers a hidden status item across launches; Limita always starts with it.
        item.isVisible = true
        store.onMenuBarIconChange = { [weak self] visible in
            self?.statusItem?.isVisible = visible
        }

        // Everything else lives in Settings; the menu keeps what is used every day.
        menu.font = AppFont.ns(13)
        showLimitsMenuItem = menu.addItem(withTitle: "Show Limits", action: #selector(showLimits), keyEquivalent: "")
        updateShowLimitsHint()
        menu.addItem(withTitle: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Limita", action: #selector(quitApp), keyEquivalent: "q")
        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    /// Left click toggles the dashboard; right click (or ⌃-click) opens the menu.
    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            guard let statusItem else { return }
            // The floating dashboard stays open under the menu.
            if !store.floatingEnabled { panelController?.hide() }
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if panelController?.isExpanded == true {
            panelController?.hide()
        } else {
            showLimits()
        }
    }

    /// Only a hint: the shortcut itself works from any app, and may be changed or off.
    private func updateShowLimitsHint() {
        guard let item = showLimitsMenuItem else { return }
        if hotKeys.isActive(.dashboard), let binding = hotKeys.binding(for: .dashboard),
           let key = binding.keyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = binding.modifierFlags
        } else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }

    // MARK: - Actions

    @objc private func showLimits() {
        // Before the status item is laid out its window frame is empty; fall back to the cursor.
        let buttonWindow = statusItem?.button?.window
        let anchor = buttonWindow.flatMap { $0.frame.width > 0 && $0.screen != nil ? $0.frame : nil }
        panelController?.showExpanded(below: anchor, on: anchor == nil ? nil : buttonWindow?.screen)
    }

    @objc private func refreshData() {
        store.refresh(live: true)
    }

    @objc private func showSettings() {
        openSettings(tab: nil)
    }

    private func openSettings(tab: SettingsTab?) {
        // The dashboard would cover the window unless it floats where the user put it.
        if !store.floatingEnabled { panelController?.hide() }
        settingsController?.show(tab: tab)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
