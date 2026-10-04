import CoreGraphics
import Foundation

/// Which edges a resize handle moves.
public struct ResizeEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let left = ResizeEdges(rawValue: 1)
    public static let right = ResizeEdges(rawValue: 2)
    public static let top = ResizeEdges(rawValue: 4)
    public static let bottom = ResizeEdges(rawValue: 8)
}

/// Pure geometry for the menu-bar panel, in AppKit screen coordinates
/// (origin bottom-left, y grows upwards).
public enum PanelPlacement {
    /// The frame after dragging `edges` by `delta` from `start`. The opposite
    /// edges stay put; the size never drops below `minimum` nor grows past
    /// `bounds` (the screen's visible frame).
    public static func resized(_ start: CGRect, edges: ResizeEdges, delta: CGSize,
                               minimum: CGSize, bounds: CGRect) -> CGRect {
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) {
            minX = min(start.minX + delta.width, start.maxX - minimum.width)
            minX = max(minX, min(bounds.minX, start.minX))
        }
        if edges.contains(.right) {
            maxX = max(start.maxX + delta.width, start.minX + minimum.width)
            maxX = min(maxX, max(bounds.maxX, start.maxX))
        }
        if edges.contains(.bottom) {
            minY = min(start.minY + delta.height, start.maxY - minimum.height)
            minY = max(minY, min(bounds.minY, start.minY))
        }
        if edges.contains(.top) {
            maxY = max(start.maxY + delta.height, start.minY + minimum.height)
            maxY = min(maxY, max(bounds.maxY, start.maxY))
        }
        return CGRect(x: minX.rounded(), y: minY.rounded(),
                      width: (maxX - minX).rounded(), height: (maxY - minY).rounded())
    }

    /// Which edges a point near the border of a `size`-sized view grabs.
    /// `point` uses a bottom-left origin. Corners get a larger target.
    public static func edges(at point: CGPoint, in size: CGSize, edge: CGFloat = 6, corner: CGFloat = 16) -> ResizeEdges {
        guard point.x >= 0, point.y >= 0, point.x <= size.width, point.y <= size.height else { return [] }
        var result: ResizeEdges = []
        let nearLeft = point.x <= corner, nearRight = point.x >= size.width - corner
        let nearBottom = point.y <= corner, nearTop = point.y >= size.height - corner
        if (nearLeft || nearRight) && (nearBottom || nearTop) {
            result.insert(nearLeft ? .left : .right)
            result.insert(nearBottom ? .bottom : .top)
            return result
        }
        if point.x <= edge { result.insert(.left) }
        if point.x >= size.width - edge { result.insert(.right) }
        if point.y <= edge { result.insert(.bottom) }
        if point.y >= size.height - edge { result.insert(.top) }
        return result
    }

    /// Clamp a requested size to a minimum and to what fits on the screen.
    public static func clampedSize(_ requested: CGSize, minimum: CGSize, visibleFrame: CGRect, margin: CGFloat = 8) -> CGSize {
        let maxWidth = max(minimum.width, visibleFrame.width - margin * 2)
        let maxHeight = max(minimum.height, visibleFrame.height - margin * 2)
        func finite(_ value: CGFloat, _ fallback: CGFloat) -> CGFloat { value.isFinite ? value : fallback }
        return CGSize(width: min(maxWidth, max(minimum.width, finite(requested.width, minimum.width))),
                      height: min(maxHeight, max(minimum.height, finite(requested.height, minimum.height))))
    }

    /// A panel hanging below the status item: horizontally centred on the icon,
    /// top edge `gap` below it, kept inside the visible frame.
    public static func anchoredFrame(size: CGSize, anchor: CGRect, visibleFrame: CGRect,
                                     minimum: CGSize, gap: CGFloat = 6, margin: CGFloat = 8) -> CGRect {
        let top = min(anchor.minY - gap, visibleFrame.maxY)
        let availableHeight = max(minimum.height, top - visibleFrame.minY - margin)
        var size = clampedSize(size, minimum: minimum, visibleFrame: visibleFrame, margin: margin)
        size.height = min(size.height, availableHeight)
        var x = anchor.midX - size.width / 2
        x = min(max(x, visibleFrame.minX + margin), visibleFrame.maxX - margin - size.width)
        return CGRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
    }

    /// Keep a free-floating (pinned) frame reachable: shrink to the screen if
    /// needed, then slide it inside the visible frame. A frame that is already
    /// fully visible is returned unchanged.
    public static func constrained(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        guard frame.width.isFinite, frame.height.isFinite, frame.origin.x.isFinite, frame.origin.y.isFinite,
              !visibleFrame.isEmpty else { return frame }
        if visibleFrame.contains(frame) { return frame }
        var result = frame
        result.size.width = min(result.width, visibleFrame.width)
        result.size.height = min(result.height, visibleFrame.height)
        result.origin.x = min(max(result.minX, visibleFrame.minX), visibleFrame.maxX - result.width)
        result.origin.y = min(max(result.minY, visibleFrame.minY), visibleFrame.maxY - result.height)
        return result
    }

    /// Decode a frame stored with NSStringFromRect-compatible "{{x, y}, {w, h}}".
    public static func validSavedFrame(_ frame: CGRect?, minimum: CGSize) -> CGRect? {
        guard let frame, frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite,
              frame.width >= minimum.width, frame.height >= minimum.height,
              frame.width < 20_000, frame.height < 20_000 else { return nil }
        return frame
    }

    /// Where to put a side tooltip of `size` next to `panel`, vertically
    /// centred on `pointerY`. Prefers the side with more room; falls back to
    /// overlapping near the pointer when neither side fits.
    public static func sideTooltipFrame(size: CGSize, panel: CGRect, pointer: CGPoint,
                                        visibleFrame: CGRect, gap: CGFloat = 8) -> CGRect {
        let leftRoom = panel.minX - visibleFrame.minX - gap
        let rightRoom = visibleFrame.maxX - panel.maxX - gap
        var origin: CGPoint
        if max(leftRoom, rightRoom) >= size.width {
            origin = CGPoint(x: rightRoom >= leftRoom ? panel.maxX + gap : panel.minX - gap - size.width,
                             y: pointer.y - size.height / 2)
        } else {
            origin = CGPoint(x: pointer.x + 18, y: pointer.y - size.height - 14)
            if origin.x + size.width > visibleFrame.maxX { origin.x = pointer.x - 18 - size.width }
        }
        origin.x = min(max(origin.x, visibleFrame.minX + 4), visibleFrame.maxX - 4 - size.width)
        origin.y = min(max(origin.y, visibleFrame.minY + 4), visibleFrame.maxY - 4 - size.height)
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}
