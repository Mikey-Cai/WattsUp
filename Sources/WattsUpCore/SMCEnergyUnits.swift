import Foundation

public enum SMCEnergyUnits {
    /// Convert a genuine energy delta to average watts. Unknown labels fail closed.
    public static func watts(delta: Int64, unit: String, elapsedSeconds: Double) -> Double? {
        guard delta >= 0, elapsedSeconds.isFinite, elapsedSeconds > 0 else { return nil }
        let scale: Double
        switch unit.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "J": scale = 1
        case "mJ": scale = 1e-3
        case "uJ", "µJ", "μJ": scale = 1e-6
        case "nJ": scale = 1e-9
        default: return nil
        }
        let result = Double(delta) * scale / elapsedSeconds
        return result.isFinite ? result : nil
    }
}
