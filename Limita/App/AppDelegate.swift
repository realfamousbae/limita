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
        menu.addItem(NSMenuItem(title: "Обновить данные", action: #selector(refreshData), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Войти в Codex...", action: #selector(loginCodex), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Войти в Claude...", action: #selector(loginClaude), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem?.menu = menu
    }

    @objc private func refreshData() {
        Task { await store.refresh() }
    }

    @objc private func loginCodex() {
        showLogin(for: .codex)
    }

    @objc private func loginClaude() {
        showLogin(for: .claude)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func showLogin(for service: Service) {
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        sheet.title = "Войти в \(service.rawValue)"
        sheet.center()
        let view = LoginSheet(service: service, store: store)
        sheet.contentView = NSHostingView(rootView: view)
        sheet.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
