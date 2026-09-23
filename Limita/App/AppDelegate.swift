import AppKit
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {

    private var bezelController: BezelPanelController?
    private let store = LimitsStore()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        bezelController = BezelPanelController(store: store)
        if CommandLine.arguments.contains("--show") {
            bezelController?.showExpanded()
        }

        setupMenuBar()

        Task {
            await store.refresh()
        }
    }

    // MARK: - Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: "Limita")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Показать лимиты", action: #selector(showLimits), keyEquivalent: "l"))
        menu.addItem(NSMenuItem(title: "Обновить данные", action: #selector(refreshData), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Подключить Claude Code…", action: #selector(configureClaude), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(quitApp), keyEquivalent: "q"))
        menu.items.filter { $0.action != nil }.forEach { $0.target = self }

        statusItem?.menu = menu
    }

    @objc private func refreshData() {
        Task { await store.refresh() }
    }

    @objc private func showLimits() {
        bezelController?.showExpanded()
    }

    @objc private func configureClaude() {
        let alert = NSAlert()
        alert.messageText = "Подключение Claude Code"
        alert.informativeText = store.configureClaudeStatusLine()
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
