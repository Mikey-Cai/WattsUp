import Foundation

/// Live reordering of vertically stacked cards while one is being dragged.
public enum CardReorder {
    /// - Parameters:
    ///   - heights: card heights, in the current order.
    ///   - index: the dragged card's current index.
    ///   - offset: how far the dragged card is drawn from its slot (positive = down).
    ///   - spacing: the gap between cards.
    /// - Returns: the card's new index and the offset that keeps it under the
    ///   pointer once the layout has moved it into that slot.
    ///
    /// A swap happens when the dragged card's leading edge crosses the middle
    /// of its neighbour. After a swap the reverse condition is at least
    /// `spacing` away, so cards of different heights never flip back and forth
    /// for the same pointer position.
    public static func step(heights: [Double], index: Int, offset: Double, spacing: Double) -> (index: Int, offset: Double) {
        guard heights.indices.contains(index) else { return (index, offset) }
        var heights = heights
        var index = index
        var offset = offset
        while index + 1 < heights.count, offset > spacing + heights[index + 1] / 2 {
            offset -= heights[index + 1] + spacing
            heights.swapAt(index, index + 1)
            index += 1
        }
        while index > 0, offset < -(spacing + heights[index - 1] / 2) {
            offset += heights[index - 1] + spacing
            heights.swapAt(index, index - 1)
            index -= 1
        }
        return (index, offset)
    }
}
