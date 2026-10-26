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
/// - The global shortcut toggles the dashboard at the top of the screen under the cursor;
///   `limita://dashboard` (the iTerm2 status-bar component) opens it there.
/// - Floating (⌃⌥P): the dashboard is pinned where the user drags it, on every Space, and
///   stays open until the shortcut, the menu-bar icon or the toggle closes it.
///
/// The notch area is left alone on purpose — see `PanelLayout`.
@MainActor
final class BezelPanelController {
    /// Width of one service column in the dashboard: both meters, the gap between them
    /// and the padding.
    nonisolated static var columnWidth: CGFloat {
        2 * ExpandedView.meterWidth + ExpandedView.meterSpacing + 2 * ExpandedView.columnPadding
    }
    /// First guess only; the dashboard reports its real height once laid out.
    static let estimatedExpandedHeight: CGFloat = 268

    /// Sizes depend on how many services are connected: no empty columns, and a
    /// prompt to connect one when there are none.
    static func pillSize(services: Int) -> CGSize {
        switch services {
        case 0: CGSize(width: 184, height: 34)
        case 1: CGSize(width: 150, height: 34)
        default: CGSize(width: 138 * CGFloat(services) - 6, height: 34)
        }
    }

    /// The dashboard widens while the prime-time badge or the update button needs more
    /// room than the columns.
    static func expandedSize(services: Int, primeTime: PrimeTimeNotice? = nil, updateButton: Bool = false) -> CGSize {
        guard services > 0 else { return CGSize(width: 300, height: 210) }
        var width = columnWidth * CGFloat(services)
        if primeTime != nil || updateButton {
            width = max(width, ExpandedView.headerWidth(primeTime: primeTime, updateButton: updateButton).rounded(.up))
        }
        return CGSize(width: width, height: estimatedExpandedHeight)
    }

    /// How long the cursor must rest at the edge, so passing through to the menu bar
    /// does not pop the pill.
    private let dwellDelay: TimeInterval = 0.3
    private let hideDelay: TimeInterval = 0.7
    private let hoverSlop: CGFloat = 20

    private let store: LimitsStore
    private let model = PanelModel()
    private let panel: NSPanel
    /// Watches mouse movement; installed only while the hover pill is on.
    private var moveMonitors: [Any] = []
    /// Closes the panel on a click elsewhere; installed only while the panel is open.
    private var clickMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var moveObserver: NSObjectProtocol?
    private var dwellTimer: Timer?
    private var hideTimer: Timer?

    /// Where the panel currently lives.
    private var layout: PanelLayout?
    private var anchorX: CGFloat = 0
    /// Opened from the pill: follows the cursor. Opened from the menu bar: stays until
    /// a click outside.
    private var hoverDriven = false

    /// The dashboard floats where the user put it instead of hanging from the menu bar.
    private var floating = false
    /// Top-left corner of the floating dashboard; it grows and shrinks downwards from it.
    private var pinnedTopLeft: CGPoint?
    /// Set while the controller moves the panel itself, so only the user's drags are saved.
    private var isPlacing = false

    init(store: LimitsStore) {
        self.store = store
        panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: Self.expandedSize(services: 2)),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The window server draws the shadow from the content's alpha, so it follows the
        // rounded dashboard and the pill capsule, and window screenshots (⌘⇧4, Space)
        // get the same shadow as other apps.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // Shown on demand, so it moves to whichever Space is active when ordered front,
        // including full-screen Spaces. `.canJoinAllSpaces` left it stuck on one desktop.
        panel.collectionBehavior = [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]

        let hosting = NSHostingView(rootView: PanelRootView(
            store: store,
            model: model,
            onExpand: { [weak self] in self?.expandFromPill() },
            onDashboardHeight: { [weak self] in self?.dashboardHeightChanged($0) }
        ))
        // The controller sizes the window; SwiftUI must not resize it.
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        setHoverEnabled(store.hoverEnabled)
        floating = store.floatingEnabled
        pinnedTopLeft = store.floatingOrigin
        applyFloatingBehaviour()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The floating dashboard stays, moved back onto a screen if its own is gone.
                if self.isFloatingShown { self.relayout() } else { self.hide() }
            }
        }
        // Switching desktops by gesture or shortcut involves no click, so without this
        // the panel would count as open on a Space the user has left.
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isFloatingShown else { return }
                self.hide(animated: false)
            }
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            // Delivered right away, while `isPlacing` still tells our moves from the user's.
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelMoved() }
        }
        observeServices()
    }

    var isExpanded: Bool { model.state == .expanded && isOnScreen }

    /// Whether the panel can actually be seen, whatever `model.state` says. The floating
    /// dashboard is on every Space.
    private var isOnScreen: Bool {
        panel.isVisible && (panel.isOnActiveSpace || isFloatingShown)
    }

    /// The dashboard is open as the floating window.
    private var isFloatingShown: Bool {
        floating && model.state == .expanded && panel.isVisible
    }

    /// A panel left on another Space, or ordered out behind our back, is hidden in
    /// practice. Treat it so, or hovering and clicking would act on a panel nobody sees.
    private func forgetOffscreenPanel() {
        if model.state != .hidden, !isOnScreen {
            model.state = .hidden
            removeClickMonitor()
        }
    }

    private func size(for state: PanelState) -> CGSize {
        let count = store.enabledServices.count
        if state == .pill { return Self.pillSize(services: count) }
        var size = Self.expandedSize(
            services: count, primeTime: store.primeTimeNotice, updateButton: store.updater.available != nil
        )
        if let measuredHeight { size.height = measuredHeight }
        return size
    }

    /// Height the dashboard content actually needs, as last reported by SwiftUI.
    private var measuredHeight: CGFloat?

    private func dashboardHeightChanged(_ height: CGFloat) {
        let height = height.rounded(.up)
        guard height > 0, height != measuredHeight else { return }
        measuredHeight = height
        relayout()
    }

    /// Resizes the open panel when a service is connected or disconnected, when
    /// peak hours start or end, or when an update button appears.
    private func observeServices() {
        withObservationTracking {
            _ = store.enabledServices
            _ = store.primeTimeServices
            _ = store.updater.available
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.relayout()
                self?.observeServices()
            }
        }
    }

    private func relayout() {
        guard model.state != .hidden, let frame = targetFrame(for: model.state) else { return }
        place(frame, display: true)
        refreshShadow()
    }

    /// Where the panel goes in `state`: the floating dashboard at its pinned corner,
    /// anything else hanging from the top of `layout`'s screen.
    private func targetFrame(for state: PanelState) -> CGRect? {
        let size = size(for: state)
        guard floating, state == .expanded else {
            return layout?.frame(size: size, anchorX: anchorX)
        }
        let topLeft = pinnedTopLeft ?? defaultPinnedTopLeft(size: size)
        let frame = PanelLayout.pinnedFrame(size: size, topLeft: topLeft, visibleFrames: NSScreen.screens.map(\.visibleFrame))
        // Never dragged: stay where it first appeared, growing downwards from there.
        if pinnedTopLeft == nil { pinnedTopLeft = CGPoint(x: frame.minX, y: frame.maxY) }
        return frame
    }

    /// Before the first drag the floating dashboard opens where the ordinary one would:
    /// where it is open now, or centred at the top of the screen under the cursor.
    private func defaultPinnedTopLeft(size: CGSize) -> CGPoint {
        let frame = layout?.frame(size: size, anchorX: anchorX) ?? {
            let screen = screenContaining(NSEvent.mouseLocation) ?? NSScreen.main
            guard let screen else { return CGRect(origin: .zero, size: size) }
            return PanelLayout(screen: screen).frame(size: size, anchorX: screen.frame.midX)
        }()
        return CGPoint(x: frame.minX, y: frame.maxY)
    }

    private func place(_ frame: CGRect, display: Bool) {
        isPlacing = true
        panel.setFrame(frame, display: display)
        isPlacing = false
    }

    /// The user dragged the floating dashboard: remember where it is now.
    private func panelMoved() {
        guard !isPlacing, isFloatingShown else { return }
        let topLeft = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        guard topLeft != pinnedTopLeft else { return }
        pinnedTopLeft = topLeft
        store.floatingOrigin = topLeft
    }

    // MARK: - Floating

    /// Pins the dashboard as a floating window, or returns it to the menu bar. Turning it
    /// on opens the dashboard there; turning it off closes it.
    func setFloating(_ enabled: Bool) {
        guard enabled != floating else { return }
        floating = enabled
        applyFloatingBehaviour()
        if enabled {
            forgetOffscreenPanel()
            hoverDriven = false
            if model.state == .expanded {
                removeClickMonitor()
                relayout()
            } else {
                transition(to: .expanded)
            }
        } else {
            hide()
        }
    }

    /// The floating dashboard can be dragged by its background and is on every Space; the
    /// ordinary one is fixed and moves to whichever Space is active when ordered front.
    private func applyFloatingBehaviour() {
        panel.isMovable = floating
        panel.isMovableByWindowBackground = floating
        panel.collectionBehavior = floating
            ? [.canJoinAllSpaces, .ignoresCycle, .fullScreenAuxiliary]
            : [.moveToActiveSpace, .ignoresCycle, .fullScreenAuxiliary]
    }

    /// The shadow is computed from what the panel shows when asked, not kept up to date,
    /// so it is recomputed after every resize and once SwiftUI's pill/dashboard spring
    /// (`PanelRootView`) has settled; otherwise it keeps the previous shape.
    private func refreshShadow() {
        panel.invalidateShadow()
        let state = model.state
        DispatchQueue.main.asyncAfter(deadline: .now() + shadowSettleDelay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.state == state, state != .hidden else { return }
                self.panel.invalidateShadow()
            }
        }
    }

    /// Long enough for the spring in `PanelRootView` to come to rest.
    private let shadowSettleDelay: TimeInterval = 0.4

    /// Opens the dashboard under `anchor` (a menu-bar item frame), or under the cursor.
    /// The floating dashboard opens where it is pinned instead.
    func showExpanded(below anchor: CGRect? = nil, on screen: NSScreen? = nil) {
        if floating { return showFloating() }
        guard let screen = screen ?? screenContaining(NSEvent.mouseLocation) ?? NSScreen.main else { return }
        layout = PanelLayout(screen: screen)
        anchorX = anchor?.midX ?? NSEvent.mouseLocation.x
        hoverDriven = false
        transition(to: .expanded)
    }

    /// The global shortcut: closes whatever is open, or opens the dashboard centred at the
    /// top of the screen the cursor is on, over whatever app is in front.
    func toggleFromShortcut() {
        forgetOffscreenPanel()
        guard model.state == .hidden else {
            hide()
            return
        }
        showAtTopOfCursorScreen()
    }

    /// Opens the dashboard centred at the top of the screen the cursor is on. Never
    /// toggles: the click that asks for it has already closed an open one.
    func showAtTopOfCursorScreen() {
        if floating { return showFloating() }
        guard let screen = screenContaining(NSEvent.mouseLocation) ?? NSScreen.main else { return }
        layout = PanelLayout(screen: screen)
        anchorX = screen.frame.midX
        hoverDriven = false
        transition(to: .expanded)
    }

    private func showFloating() {
        hoverDriven = false
        transition(to: .expanded)
    }

    func hide(animated: Bool = true) {
        transition(to: .hidden, animated: animated)
    }

    // MARK: - Mouse tracking

    /// Turns hover tracking on or off. Off removes the mouse-move monitors altogether,
    /// so Limita is not woken by mouse movement.
    func setHoverEnabled(_ enabled: Bool) {
        if enabled {
            guard moveMonitors.isEmpty else { return }
            let moved: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
            if let global = NSEvent.addGlobalMonitorForEvents(matching: moved, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
            }) {
                moveMonitors.append(global)
            }
            if let local = NSEvent.addLocalMonitorForEvents(matching: moved, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
                return event
            }) {
                moveMonitors.append(local)
            }
        } else {
            moveMonitors.forEach(NSEvent.removeMonitor)
            moveMonitors = []
            cancel(&dwellTimer)
            cancel(&hideTimer)
            if model.state == .pill { hide() }
        }
    }

    /// Clicks in other apps close the panel. Clicks inside Limita arrive locally and
    /// are handled by the panel or the status item.
    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func mouseMoved(to point: CGPoint) {
        forgetOffscreenPanel()
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
        forgetOffscreenPanel()
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
        // The floating dashboard does not follow the cursor.
        if floating { hoverDriven = false }
        transition(to: .expanded)
    }

    // MARK: - Presentation

    private func transition(to state: PanelState, animated: Bool = true) {
        cancel(&hideTimer)
        cancel(&dwellTimer)
        forgetOffscreenPanel()
        guard state != model.state else {
            if state != .hidden { panel.orderFrontRegardless() }
            return
        }

        switch state {
        case .hidden:
            model.state = .hidden
            removeClickMonitor()
            store.setupMessage = nil
            guard animated else {
                panel.alphaValue = 0
                panel.orderOut(nil)
                return
            }
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
            guard let frame = targetFrame(for: state) else { return }
            let wasHidden = model.state == .hidden
            place(frame, display: false)
            model.state = state
            // Only the shortcut, the menu-bar icon or the toggle closes the floating dashboard.
            if floating, state == .expanded {
                removeClickMonitor()
            } else {
                installClickMonitor()
            }
            if wasHidden { panel.alphaValue = 0 }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                panel.animator().alphaValue = 1
            }
            refreshShadow()
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
    let onDashboardHeight: (CGFloat) -> Void

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
                    .background(GeometryReader { geometry in
                        Color.clear.preference(key: DashboardHeightKey.self, value: geometry.size.height)
                    })
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(DashboardHeightKey.self, perform: onDashboardHeight)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: model.state)
    }
}

private struct DashboardHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
