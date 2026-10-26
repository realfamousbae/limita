import AppKit

/// Pure geometry for placing the pill and the expanded panel on one screen.
///
/// Everything happens along the top edge of the screen except the camera housing:
/// another app owns the notch area, so Limita neither triggers there nor draws there.
struct PanelLayout: Equatable {
    /// How far from the top edge the cursor must be to count as "at the edge".
    static let triggerHeight: CGFloat = 3
    /// Extra room kept clear on each side of the notch, since notch apps grow beyond it.
    static let notchClearance: CGFloat = 80
    static let screenInset: CGFloat = 8
    static let gapBelowMenuBar: CGFloat = 6

    let screenFrame: CGRect
    let menuBarHeight: CGFloat
    /// Horizontal span Limita must stay out of, or `nil` on screens without a notch.
    let excludedSpan: ClosedRange<CGFloat>?

    init(screenFrame: CGRect, menuBarHeight: CGFloat, notchSpan: ClosedRange<CGFloat>?) {
        self.screenFrame = screenFrame
        self.menuBarHeight = menuBarHeight
        self.excludedSpan = notchSpan.map {
            ($0.lowerBound - Self.notchClearance)...($0.upperBound + Self.notchClearance)
        }
    }

    @MainActor
    init(screen: NSScreen) {
        let frame = screen.frame
        self.init(
            screenFrame: frame,
            menuBarHeight: max(screen.safeAreaInsets.top, frame.maxY - screen.visibleFrame.maxY, 24),
            notchSpan: screen.notchSpan
        )
    }

    func isTrigger(_ point: CGPoint) -> Bool {
        guard point.y >= screenFrame.maxY - Self.triggerHeight,
              point.x >= screenFrame.minX, point.x <= screenFrame.maxX
        else { return false }
        return !(excludedSpan?.contains(point.x) ?? false)
    }

    /// A frame of `size` hanging below the menu bar, centred on `anchorX` as far as the
    /// screen edges and the excluded span allow.
    func frame(size: CGSize, anchorX: CGFloat) -> CGRect {
        let minX = screenFrame.minX + Self.screenInset
        let maxX = screenFrame.maxX - Self.screenInset - size.width
        var x = clamp(anchorX - size.width / 2, minX, maxX)

        if let span = excludedSpan, x < span.upperBound, x + size.width > span.lowerBound {
            let leftX = span.lowerBound - size.width
            let rightX = span.upperBound
            let leftFits = leftX >= minX
            let rightFits = rightX <= maxX
            let preferLeft = anchorX < (span.lowerBound + span.upperBound) / 2
            switch (leftFits, rightFits) {
            case (true, true): x = preferLeft ? leftX : rightX
            case (true, false): x = leftX
            case (false, true): x = rightX
            case (false, false): break // screen too narrow to avoid it; stay on screen
            }
        }

        let y = screenFrame.maxY - menuBarHeight - Self.gapBelowMenuBar - size.height
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// The floating dashboard: a frame of `size` with its top-left corner at `topLeft`,
    /// moved just enough to lie within the visible frame of the screen nearest to that
    /// corner. A screen that has since gone leaves the window on the nearest one left.
    static func pinnedFrame(size: CGSize, topLeft: CGPoint, visibleFrames: [CGRect]) -> CGRect {
        let unclamped = CGRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        guard let screen = visibleFrames.min(by: { distance(topLeft, $0) < distance(topLeft, $1) }) else {
            return unclamped
        }
        // A window larger than the screen keeps its top-left corner on it.
        let x = max(screen.minX, min(topLeft.x, screen.maxX - size.width))
        let top = min(screen.maxY, max(topLeft.y, screen.minY + size.height))
        return CGRect(x: x, y: top - size.height, width: size.width, height: size.height)
    }

    private static func distance(_ point: CGPoint, _ rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        max(lower, min(value, upper))
    }
}

extension NSScreen {
    /// Horizontal extent of the camera housing in global coordinates.
    var notchSpan: ClosedRange<CGFloat>? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea
        else { return nil }
        // Only the widths are used, so the areas' coordinate space does not matter.
        let lower = frame.minX + left.width
        let upper = frame.maxX - right.width
        return lower < upper ? lower...upper : nil
    }
}
