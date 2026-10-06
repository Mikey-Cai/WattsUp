import Foundation

/// Card order and visibility. The saved order always lists every card, shown
/// or not, so a hidden card comes back where it was.
public enum CardOrdering {
    /// Restores a saved order: unknown ids are dropped, duplicates removed, and
    /// cards the save does not know about (added in a later version) appended
    /// in their default order.
    public static func restore(saved: [String]?, all: [String]) -> [String] {
        var result: [String] = []
        for id in saved ?? [] where all.contains(id) && !result.contains(id) { result.append(id) }
        for id in all where !result.contains(id) { result.append(id) }
        return result
    }

    /// Moves `card` so that it sits at `visibleIndex` among the visible cards.
    /// Hidden cards keep their slots; only the visible slots are reshuffled.
    public static func move(_ card: String, toVisibleIndex visibleIndex: Int, order: [String], visible: Set<String>) -> [String] {
        var shown = order.filter(visible.contains)
        guard let from = shown.firstIndex(of: card), shown.indices.contains(visibleIndex), from != visibleIndex else { return order }
        shown.remove(at: from)
        shown.insert(card, at: visibleIndex)
        var result = order
        let slots = order.indices.filter { visible.contains(order[$0]) }
        for (slot, id) in zip(slots, shown) { result[slot] = id }
        return result
    }

    /// Hiding is refused when it would leave no card at all.
    public static func canHide(_ card: String, hidden: Set<String>, all: [String]) -> Bool {
        all.contains { $0 != card && !hidden.contains($0) }
    }
}
