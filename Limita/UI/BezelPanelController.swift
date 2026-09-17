import AppKit
import SwiftUI

/// Manages the borderless NSPanel that floats at the top of the screen.
/// Three visual states: hidden → pill (hover) → expanded (click).
@MainActor
final class BezelPanelController {

    private var panel: NSPanel?
    private var hostingView: NSHostingView<BezelRootView>?
    private var hideTimer: Timer?

    private var appState: AppState = .hidden {
        didSet { guard oldValue != appState else { return }; updatePanel() }
    }

    private let store: LimitsStore

    // Hot zone height (invisible trigger area at top of screen)
    private let triggerHeight: CGFloat = 4
    private let pillWidth: CGFloat = 130
    private let expandedWidth: CGFloat = 300

    init(store: LimitsStore) {
        self.store = store
        setupPanel()
        setupMouseMonitor()
    }

    // MARK: - Panel setup

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame

        let panel = NSPanel(
            contentRect: pillRect(screen: screenFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.isMovable = false

        let rootView = BezelRootView(store: store, appState: appState, onStateChange: { [weak self] newState in
            self?.appState = newState
        })
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = panel.contentView!.bounds
        hosting.autoresizingMask = [.width, .height]
        panel.contentView?.addSubview(hosting)
        self.hostingView = hosting
        self.panel = panel

        panel.alphaValue = 0
        panel.orderFront(nil)
    }

    private func setupMouseMonitor() {
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMouseMove(NSEvent.mouseLocation)
            }
        }
    }

    private func handleMouseMove(_ location: NSPoint) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let topZone = screenFrame.maxY - triggerHeight

        let inTriggerZone = location.y >= topZone

        switch appState {
        case .hidden:
            if inTriggerZone { showPill() }
        case .pill:
            guard let panel else { return }
            let expandedFrame = panel.frame.insetBy(dx: -20, dy: -20)
            if !expandedFrame.contains(location) {
                scheduleHide()
            } else {
                cancelHideTimer()
            }
        case .expanded:
            guard let panel else { return }
            let expandedFrame = panel.frame.insetBy(dx: -20, dy: -20)
            if !expandedFrame.contains(location) {
                scheduleHide()
            } else {
                cancelHideTimer()
            }
        }
    }

    // MARK: - State transitions

    private func showPill() {
        cancelHideTimer()
        appState = .pill
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

    // MARK: - Panel geometry & animation

    private func pillRect(screen: NSRect) -> NSRect {
        let x = screen.midX - pillWidth / 2
        let y = screen.maxY - 60
        return NSRect(x: x, y: y, width: pillWidth, height: 44)
    }

    private func expandedRect(screen: NSRect) -> NSRect {
        let x = screen.midX - expandedWidth / 2
        let y = screen.maxY - 240
        return NSRect(x: x, y: y, width: expandedWidth, height: 220)
    }

    private func updatePanel() {
        guard let panel, let screen = NSScreen.main else { return }

        let targetRect: NSRect
        let targetAlpha: CGFloat

        switch appState {
        case .hidden:
            targetRect = pillRect(screen: screen.frame)
            targetAlpha = 0
        case .pill:
            targetRect = pillRect(screen: screen.frame)
            targetAlpha = 1
        case .expanded:
            targetRect = expandedRect(screen: screen.frame)
            targetAlpha = 1
        }

        // Update SwiftUI with new state
        hostingView?.rootView = BezelRootView(store: store, appState: appState, onStateChange: { [weak self] newState in
            self?.appState = newState
        })

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(targetRect, display: true)
            panel.animator().alphaValue = targetAlpha
        }
    }
}

// MARK: - SwiftUI Root

struct BezelRootView: View {
    var store: LimitsStore
    var appState: AppState
    var onStateChange: (AppState) -> Void

    var body: some View {
        ZStack {
            if appState == .pill {
                MiniPillView(store: store)
                    .onTapGesture { onStateChange(.expanded) }
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            } else if appState == .expanded {
                ExpandedView(store: store)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: appState)
    }
}
