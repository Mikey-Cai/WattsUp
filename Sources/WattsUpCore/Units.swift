import Foundation

public enum Units {
    public static let bytesPerGiB = 1_073_741_824.0
    public static let bytesPerMiB = 1_048_576.0

    public static func gibibytes(_ bytes: Double) -> Double { bytes / bytesPerGiB }

    /// Use the numeric conversion explicitly: a reference to Double.init can
    /// resolve to the UInt64 bitPattern initializer on newer Swift toolchains.
    public static func scalarBytes(_ bytes: UInt64?) -> Double? { bytes.map { Double($0) } }

    public static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未知" }
        return String(format: "%.2f W", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// Match Activity Monitor labels while retaining binary (1024) conversion.
    public static func memory(_ bytes: Double?) -> String {
        guard let bytes, bytes.isFinite, bytes >= 0 else { return "未知" }
        if bytes == 0 { return "0 GB" }
        if bytes < bytesPerGiB {
            return String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), bytes / bytesPerMiB)
        }
        return String(format: "%.2f GB", locale: Locale(identifier: "en_US_POSIX"), gibibytes(bytes))
    }

    /// Disk and network speed in decimal units, like Activity Monitor's
    /// "数据读取/秒": KB/s below 1 MB/s, GB/s from 1000 MB/s up.
    public static func rate(_ bytesPerSecond: Double?) -> String {
        guard let value = bytesPerSecond, value.isFinite, value >= 0 else { return "未知" }
        let posix = Locale(identifier: "en_US_POSIX")
        if value < 1e6 { return String(format: "%.0f KB/s", locale: posix, value / 1e3) }
        if value < 1e8 { return String(format: "%.1f MB/s", locale: posix, value / 1e6) }
        if value < 1e9 { return String(format: "%.0f MB/s", locale: posix, value / 1e6) }
        return String(format: "%.2f GB/s", locale: posix, value / 1e9)
    }

    /// A 0…1 fraction as a whole percentage, clamped.
    public static func percent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return "未知" }
        return "\(Int((min(1, max(0, fraction)) * 100).rounded()))%"
    }
}
