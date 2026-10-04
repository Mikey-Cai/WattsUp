import Foundation

public struct SankeyBand: Equatable, Sendable {
    public let index: Int
    public let value: Double
    public let sourceY: Double
    public let targetY: Double
    public let thickness: Double
}

public struct SankeyGeometry: Equatable, Sendable {
    public let bands: [SankeyBand]
    public let scale: Double
    public let total: Double
    public let height: Double
    public let sourceTop: Double
    public let sourceHeight: Double
}

/// A single source split into ordered destinations. Every band uses the same
/// value-to-pixel scale; tiny values are never visually inflated.
public enum SankeyLayout {
    public static func make(values: [Double], height: Double, gap: Double = 8) -> SankeyGeometry {
        let height = height.isFinite ? max(0, height) : 0
        let valid = values.enumerated().filter { $0.element.isFinite && $0.element > 0 }
        let total = valid.reduce(0) { $0 + $1.element }
        guard total.isFinite, total > 0, height > 0 else {
            return SankeyGeometry(bands: [], scale: 0, total: total.isFinite ? total : 0,
                                  height: height, sourceTop: height / 2, sourceHeight: 0)
        }
        let gaps = max(0, valid.count - 1)
        // Preserve room for actual values even in very short layouts.
        let requestedGap = gap.isFinite ? max(0, gap) : 0
        let actualGap = gaps > 0 ? min(requestedGap, height * 0.4 / Double(gaps)) : 0
        let sourceHeight = height - actualGap * Double(gaps)
        let scale = sourceHeight / total
        let sourceTop = (height - sourceHeight) / 2
        var sourceY = sourceTop
        var targetY = 0.0
        var bands: [SankeyBand] = []
        for item in valid {
            let thickness = item.element * scale
            bands.append(SankeyBand(index: item.offset, value: item.element,
                                    sourceY: sourceY, targetY: targetY, thickness: thickness))
            sourceY += thickness
            targetY += thickness + actualGap
        }
        return SankeyGeometry(bands: bands, scale: scale, total: total, height: height,
                              sourceTop: sourceTop, sourceHeight: sourceHeight)
    }
}
