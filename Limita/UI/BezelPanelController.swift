import AppKit
import SwiftUI

/// Owns the menu-bar panel. It deliberately avoids the camera/notch area.
@MainActor
final class BezelPanelController {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<BezelRootView>?
    private var hideTimer: Timer?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var currentScreen: NSScreen?

    private var appState: AppState = .hidden {
        didSet {
            guard oldValue != appState else { return }
            updatePanel()
        }
    }

    private let store: LimitsStore
    private let expandedWidth: CGFloat = 520
    private let expandedHeight: CGFloat = 212

    init(store: LimitsStore) {
        self.store = store
        currentScreen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        setupPanel()
        setupMouseMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updatePanel() }
        }
    }

    deinit {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    func showExpanded() {
        cancelHideTimer()
        currentScreen = screen(containing: NSEvent.mouseLocation) ?? NSScreen.main
        if appState == .expanded {
            updatePanel()
            panel?.orderFrontRegardless()
        } else {
            appState = .expanded
        }
    }

    private func setupPanel() {
        guard let currentScreen else { return }
        let panel = NSPanel(
            contentRect: expandedRect(screen: currentScreen),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.isMovable = false

        let rootView = makeRootView()
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)

        hostingView = hosting
        self.panel = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
    }

    private func setupMouseMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleMouseMove(NSEvent.mouseLocation) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleMouseMove(NSEvent.mouseLocation) }
            return event
        }
    }

    private func handleMouseMove(_ location: NSPoint) {
        switch appState {
        case .hidden:
            return
        case .expanded:
            guard let panel else { return }
            let hitArea = panel.frame.insetBy(dx: -20, dy: -20)
            if hitArea.contains(location) {
                cancelHideTimer()
            } else {
                scheduleHide()
            }
        }
    }

    private func scheduleHide() {
        guard hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideTimer = nil
                self?.appState = .hidden
            }
        }
    }

    private func cancelHideTimer() {
        hideTimer?.invalidate()
        hideTimer = nil
    }

    private func expandedRect(screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let menuBarHeight = max(screen.safeAreaInsets.top, frame.maxY - screen.visibleFrame.maxY)
        return NSRect(
            x: frame.maxX - expandedWidth - 14,
            y: frame.maxY - menuBarHeight - expandedHeight - 10,
            width: expandedWidth,
            height: expandedHeight
        )
    }

    private func updatePanel() {
        guard let panel, let currentScreen = currentScreen ?? NSScreen.main else { return }
        self.currentScreen = currentScreen

        let targetRect: NSRect
        let targetAlpha: CGFloat
        switch appState {
        case .hidden:
            targetRect = expandedRect(screen: currentScreen)
            targetAlpha = 0
            panel.ignoresMouseEvents = true
        case .expanded:
            targetRect = expandedRect(screen: currentScreen)
            targetAlpha = 1
            panel.ignoresMouseEvents = false
        }

        hostingView?.rootView = makeRootView()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetRect, display: true)
            panel.animator().alphaValue = targetAlpha
        }
    }

    private func makeRootView() -> BezelRootView {
        BezelRootView(store: store, appState: appState) { [weak self] state in
            self?.appState = state
        }
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

struct BezelRootView: View {
    var store: LimitsStore
    var appState: AppState
    var onStateChange: (AppState) -> Void

    var body: some View {
        ZStack {
            if appState == .expanded {
                ExpandedView(store: store)
                    .transition(.scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState)
    }
}
