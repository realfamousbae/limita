import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = LimitsStore()
    private var panelController: BezelPanelController?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    /// One Connect/Disconnect row per service, in display order.
    private var serviceMenuItems: [Service: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store.repairClaudeHookIfNeeded()
        store.startAutoRefresh()

        panelController = BezelPanelController(store: store)
        setupStatusItem()

        if CommandLine.arguments.contains("--show") {
            // The status item is positioned on the next layout pass.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showLimits()
            }
        }
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

        menu.delegate = self
        menu.font = AppFont.ns(13)
        menu.addItem(withTitle: "Show Limits", action: #selector(showLimits), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
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
            panelController?.hide()
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
