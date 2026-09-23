import AppKit
import SwiftUI

enum PanelState: Equatable {
    case hidden
    case pill
    case expanded
}

/// Shared between the controller and the SwiftUI content, so state changes re-render
/// without rebuilding the hosting view.
@Observable
@MainActor
final class PanelModel {
    var state: PanelState = .hidden
}

/// Owns the floating panel.
///
/// - Resting the cursor at the top edge of any screen shows a compact pill there;
///   clicking it expands the full dashboard. Moving away hides it again.
/// - The menu-bar icon opens the dashboard directly; a click outside closes it.
///
/// The notch area is left alone on purpose — see `PanelLayout`.
@MainActor
final class BezelPanelController {
    static let pillSize = CGSize(width: 204, height: 34)
    static let expandedSize = CGSize(width: 520, height: 256)

    /// How long the cursor must rest at the edge, so passing through to the menu bar
    /// does not pop the pill.
    private let dwellDelay: TimeInterval = 0.3
    private let hideDelay: TimeInterval = 0.7
    private let hoverSlop: CGFloat = 20

    private let store: LimitsStore
    private let model = PanelModel()
    private let panel: NSPanel
    private var monitors: [Any] = []
    private var screenObserver: NSObjectProtocol?
    private var dwellTimer: Timer?
    private var hideTimer: Timer?

    /// Where the panel currently lives.
    private var layout: PanelLayout?
    private var anchorX: CGFloat = 0
    /// Opened from the pill: follows the cursor. Opened from the menu bar: stays until
    /// a click outside.
    private var hoverDriven = false

    init(store: LimitsStore) {
        self.store = store
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.expandedSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: PanelRootView(store: store, model: model) { [weak self] in
            self?.expandFromPill()
        })
        // The controller sizes the window; SwiftUI must not resize it.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        installMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    var isExpanded: Bool { model.state == .expanded }

    /// Opens the dashboard under `anchor` (a menu-bar item frame), or under the cursor.
    func showExpanded(below anchor: CGRect? = nil, on screen: NSScreen? = nil) {
        guard let screen = screen ?? screenContaining(NSEvent.mouseLocation) ?? NSScreen.main else { return }
        layout = PanelLayout(screen: screen)
        anchorX = anchor?.midX ?? NSEvent.mouseLocation.x
        hoverDriven = false
        transition(to: .expanded)
    }

    func hide() {
        transition(to: .hidden)
    }

    // MARK: - Mouse tracking

    private func installMonitors() {
        let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
            return event
        }) {
            monitors.append(local)
        }
        // Clicks in other apps close the panel. Clicks inside Limita arrive locally and
        // are handled by the panel or the status item.
        if let clicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) {
            monitors.append(clicks)
        }
    }

    private func mouseMoved(to point: CGPoint) {
        switch model.state {
        case .hidden:
            updateDwell(at: point)
        case .pill:
            trackHover(at: point)
        case .expanded:
            if hoverDriven { trackHover(at: point) }
        }
    }

    private func updateDwell(at point: CGPoint) {
        let atEdge = screenContaining(point).map { PanelLayout(screen: $0).isTrigger(point) } ?? false
        guard atEdge else {
            cancel(&dwellTimer)
            return
        }
        guard dwellTimer == nil else { return }
        dwellTimer = Timer.scheduledTimer(withTimeInterval: dwellDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dwellElapsed() }
        }
    }

    private func dwellElapsed() {
        dwellTimer = nil
        let point = NSEvent.mouseLocation
        guard model.state == .hidden,
              let screen = screenContaining(point)
        else { return }
        let layout = PanelLayout(screen: screen)
        guard layout.isTrigger(point) else { return }

        self.layout = layout
        anchorX = point.x
        hoverDriven = true
        transition(to: .pill)
    }

    /// Keeps the panel open while the cursor is over it or on the way to it from the edge.
    private func trackHover(at point: CGPoint) {
        guard let layout else { return }
        var zone = panel.frame
        // Include the strip between the top edge and the pill, which the cursor crosses.
        zone = zone.union(CGRect(x: zone.minX, y: zone.maxY, width: zone.width, height: layout.screenFrame.maxY - zone.maxY))
        if zone.insetBy(dx: -hoverSlop, dy: -hoverSlop).contains(point) {
            cancel(&hideTimer)
        } else if hideTimer == nil {
            hideTimer = Timer.scheduledTimer(withTimeInterval: hideDelay, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hideTimer = nil
                    self?.hide()
                }
            }
        }
    }

    private func expandFromPill() {
        guard model.state == .pill else { return }
        transition(to: .expanded)
    }

    // MARK: - Presentation

    private func transition(to state: PanelState) {
        cancel(&hideTimer)
        cancel(&dwellTimer)
        guard state != model.state else {
            if state != .hidden { panel.orderFrontRegardless() }
            return
        }

        switch state {
        case .hidden:
            model.state = .hidden
            store.claudeSetupMessage = nil
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.state == .hidden else { return }
                    self.panel.orderOut(nil)
                }
            })

        case .pill, .expanded:
            guard let layout else { return }
            let size = state == .pill ? Self.pillSize : Self.expandedSize
            let wasHidden = model.state == .hidden
            panel.setFrame(layout.frame(size: size, anchorX: anchorX), display: false)
            model.state = state
            if wasHidden { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
            store.refreshIfOlder(than: 15)
        }
    }

    private func cancel(_ timer: inout Timer?) {
        timer?.invalidate()
        timer = nil
    }

    private func screenContaining(_ point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}

struct PanelRootView: View {
    let store: LimitsStore
    let model: PanelModel
    let onExpand: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            switch model.state {
            case .hidden:
                Color.clear
            case .pill:
                MiniPillView(store: store)
                    .onTapGesture(perform: onExpand)
                    .transition(.scale(scale: 0.9, anchor: .top).combined(with: .opacity))
            case .expanded:
                ExpandedView(store: store)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.state)
    }
}
