import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = LimitsStore()
    private var panelController: BezelPanelController?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private let claudeMenuItem = NSMenuItem()

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
            button.image = NSImage(systemSymbolName: "gauge.with.dots.needle.50percent", accessibilityDescription: "Limita")
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        menu.delegate = self
        menu.addItem(withTitle: "Show Limits", action: #selector(showLimits), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh", action: #selector(refreshData), keyEquivalent: "r")
        menu.addItem(.separator())
        claudeMenuItem.target = self
        menu.addItem(claudeMenuItem)
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
        if store.isClaudeConnected {
            claudeMenuItem.title = "Disconnect Claude Code"
            claudeMenuItem.action = #selector(disconnectClaude)
        } else {
            claudeMenuItem.title = "Connect Claude Code…"
            claudeMenuItem.action = #selector(connectClaude)
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

    @objc private func connectClaude() {
        store.connectClaude()
        presentSetupMessage()
    }

    @objc private func disconnectClaude() {
        store.disconnectClaude()
        presentSetupMessage()
    }

    private func presentSetupMessage() {
        guard let message = store.claudeSetupMessage else { return }
        store.claudeSetupMessage = nil
        // An accessory app's alert opens behind other windows unless we activate first.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Claude Code"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
