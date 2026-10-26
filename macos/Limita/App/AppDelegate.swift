import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = LimitsStore()
    private var panelController: BezelPanelController?
    private var statusItem: NSStatusItem?
    private var dashboardHotKey: GlobalHotKey?
    private var hoverHotKey: GlobalHotKey?
    private var floatingHotKey: GlobalHotKey?
    private var hoverMenuItem: NSMenuItem?
    private var floatingMenuItem: NSMenuItem?
    private var resetNotificationsMenuItem: NSMenuItem?
    private let menu = NSMenu()
    /// One Connect/Disconnect row per service, in display order.
    private var serviceMenuItems: [Service: NSMenuItem] = [:]

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
        dashboardHotKey = GlobalHotKey(
            keyCode: GlobalHotKey.dashboard.keyCode,
            modifiers: GlobalHotKey.dashboard.carbonModifiers
        ) { [weak self] in
            self?.panelController?.toggleFromShortcut()
        }
        store.onHoverEnabledChange = { [weak self] enabled in
            self?.panelController?.setHoverEnabled(enabled)
        }
        hoverHotKey = GlobalHotKey(
            id: 2,
            keyCode: GlobalHotKey.hoverToggle.keyCode,
            modifiers: GlobalHotKey.hoverToggle.carbonModifiers
        ) { [weak self] in
            self?.store.hoverEnabled.toggle()
        }
        store.onFloatingChange = { [weak self] enabled in
            self?.panelController?.setFloating(enabled)
        }
        floatingHotKey = GlobalHotKey(
            id: 3,
            keyCode: GlobalHotKey.floatingToggle.keyCode,
            modifiers: GlobalHotKey.floatingToggle.carbonModifiers
        ) { [weak self] in
            self?.store.floatingEnabled.toggle()
        }
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

    /// `limita://dashboard`, opened by the iTerm2 status-bar component.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: { $0.scheme == "limita" && $0.host == "dashboard" }) else { return }
        panelController?.showAtTopOfCursorScreen()
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

        menu.delegate = self
        menu.font = AppFont.ns(13)
        let show = menu.addItem(withTitle: "Show Limits", action: #selector(showLimits), keyEquivalent: "")
        if dashboardHotKey != nil {
            // Only a hint here: the shortcut itself works from any app.
            show.keyEquivalent = GlobalHotKey.dashboardKeyEquivalent
            show.keyEquivalentModifierMask = GlobalHotKey.dashboardModifiers
        }
        menu.addItem(withTitle: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
        let hover = menu.addItem(withTitle: "Hover Pill", action: #selector(toggleHover), keyEquivalent: "")
        if hoverHotKey != nil {
            hover.keyEquivalent = GlobalHotKey.hoverToggleKeyEquivalent
            hover.keyEquivalentModifierMask = GlobalHotKey.dashboardModifiers
        }
        hoverMenuItem = hover
        let floating = menu.addItem(withTitle: "Floating Window", action: #selector(toggleFloating), keyEquivalent: "")
        if floatingHotKey != nil {
            floating.keyEquivalent = GlobalHotKey.floatingToggleKeyEquivalent
            floating.keyEquivalentModifierMask = GlobalHotKey.dashboardModifiers
        }
        floatingMenuItem = floating
        resetNotificationsMenuItem = menu.addItem(
            withTitle: "Reset Notifications", action: #selector(toggleResetNotifications), keyEquivalent: ""
        )
        menu.addItem(.separator())
        for service in Service.allCases {
            let item = NSMenuItem(title: "", action: #selector(toggleService(_:)), keyEquivalent: "")
            item.representedObject = service.rawValue
            serviceMenuItems[service] = item
            menu.addItem(item)
        }
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        hoverMenuItem?.state = store.hoverEnabled ? .on : .off
        floatingMenuItem?.state = store.floatingEnabled ? .on : .off
        resetNotificationsMenuItem?.state = store.resets.notificationsEnabled ? .on : .off
        for (service, item) in serviceMenuItems {
            item.title = Self.menuTitle(for: service, connected: store.isEnabled(service))
        }
    }

    static func menuTitle(for service: Service, connected: Bool) -> String {
        "\(connected ? "Disconnect" : "Connect") \(service.productName)"
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

    @objc private func toggleHover() {
        store.hoverEnabled.toggle()
    }

    @objc private func toggleFloating() {
        store.floatingEnabled.toggle()
    }

    @objc private func toggleResetNotifications() {
        store.resets.notificationsEnabled.toggle()
    }

    @objc private func toggleService(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let service = Service(rawValue: raw) else { return }
        if store.isEnabled(service) {
            store.disconnect(service)
        } else {
            store.connect(service)
        }
        presentSetupMessage()
    }

    /// From the menu there is no panel to show the outcome in, so use an alert.
    private func presentSetupMessage() {
        guard let message = store.setupMessage else { return }
        store.setupMessage = nil
        // An accessory app's alert opens behind other windows unless we activate first.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message.service.productName
        alert.informativeText = message.text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
