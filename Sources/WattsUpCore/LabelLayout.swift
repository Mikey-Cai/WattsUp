import Foundation

/// Keeps stacked Sankey destination labels from overlapping. Each label wants
/// to sit centred on its band; thin neighbouring bands would otherwise make
/// their two-line labels collide. Order is preserved and labels move as
/// little as possible.
public enum LabelLayout {
    /// - Parameters:
    ///   - centers: desired label centre y for each label, top to bottom (y grows downwards).
    ///   - heights: label heights.
    ///   - spacing: minimum free space between neighbours.
    ///   - minY/maxY: the area labels must stay within.
    public static func resolve(centers: [Double], heights: [Double], spacing: Double = 2,
                               minY: Double, maxY: Double) -> [Double] {
        let count = min(centers.count, heights.count)
        guard count > 0 else { return [] }
        var result = Array(centers.prefix(count))
        let h = Array(heights.prefix(count))
        // Downward pass: push each label below its predecessor.
        result[0] = max(result[0], minY + h[0] / 2)
        if count > 1 {
            for i in 1..<count {
                let lowest = result[i - 1] + (h[i - 1] + h[i]) / 2 + spacing
                result[i] = max(result[i], lowest)
            }
        }
        // Upward pass: if the stack overflows the bottom, pull it back up.
        result[count - 1] = min(result[count - 1], maxY - h[count - 1] / 2)
        if count > 1 {
            for i in stride(from: count - 2, through: 0, by: -1) {
                let highest = result[i + 1] - (h[i + 1] + h[i]) / 2 - spacing
                result[i] = min(result[i], highest)
            }
        }
        // If even that cannot fit, keep order from the top rather than inverting.
        result[0] = max(result[0], minY + h[0] / 2)
        if count > 1 {
            for i in 1..<count {
                result[i] = max(result[i], result[i - 1] + (h[i - 1] + h[i]) / 2 + spacing)
            }
        }
        return result
    }
}
