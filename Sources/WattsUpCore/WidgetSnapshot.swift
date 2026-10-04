import Foundation

/// The small JSON file the menu-bar app drops into the shared App Group
/// container for the desktop widget. Self-contained on purpose: the widget
/// extension compiles this file without the rest of WattsUpCore's hardware types.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    /// macOS accepts "<TeamID>." App Groups without a portal registration.
    /// build.sh writes "<TeamID>.io.github.mikey-cai.wattsup" into both
    /// Info.plists (key `WattsUpAppGroup`) when it is given a Team ID; builds
    /// without one have no App Group and ship without the widget.
    public static var appGroupIdentifier: String? { appGroup(fromInfo: Bundle.main.infoDictionary) }
    public static let appGroupSuffix = "io.github.mikey-cai.wattsup"
    public static let appGroupInfoKey = "WattsUpAppGroup"
    public static let fileName = "widget-snapshot.json"
    public static let widgetKind = "io.github.mikey-cai.wattsup.widget"
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var timestamp: Date
    public var totalWatts: Double?
    public var cpuEstimateWatts: Double?
    public var gpuWatts: Double?
    public var memoryUsedBytes: UInt64?
    public var memoryTotalBytes: UInt64?
    public var swapUsedBytes: UInt64?
    /// MemoryPressureLevel raw value: normal / warning / critical / unknown.
    public var pressure: String

    public init(timestamp: Date, totalWatts: Double?, cpuEstimateWatts: Double?, gpuWatts: Double?,
                memoryUsedBytes: UInt64?, memoryTotalBytes: UInt64?, swapUsedBytes: UInt64?, pressure: String) {
        self.schemaVersion = Self.currentSchema
        self.timestamp = timestamp
        self.totalWatts = totalWatts
        self.cpuEstimateWatts = cpuEstimateWatts
        self.gpuWatts = gpuWatts
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.swapUsedBytes = swapUsedBytes
        self.pressure = pressure
    }

    public var memoryUsedFraction: Double? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0, used <= total else { return nil }
        return Double(used) / Double(total)
    }

    /// The app samples every minute while a widget is installed; anything much
    /// older means WattsUp is not running.
    public func isStale(now: Date = Date(), threshold: TimeInterval = 10 * 60) -> Bool {
        now.timeIntervalSince(timestamp) > threshold || timestamp.timeIntervalSince(now) > 120
    }

    public var pressureTitle: String {
        switch pressure {
        case "normal": return "正常"
        case "warning": return "警告"
        case "critical": return "严重"
        default: return "未知"
        }
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func encoded() throws -> Data { try Self.encoder().encode(self) }

    /// Rejects files from a newer, incompatible schema instead of misreading them.
    public static func decode(_ data: Data) -> WidgetSnapshot? {
        guard let value = try? decoder().decode(WidgetSnapshot.self, from: data),
              value.schemaVersion == currentSchema else { return nil }
        return value
    }

    /// Accepts only a filled-in "<TeamID>.io.github.mikey-cai.wattsup".
    public static func appGroup(fromInfo info: [String: Any]?) -> String? {
        guard let value = info?[appGroupInfoKey] as? String else { return nil }
        let team = value.dropLast(appGroupSuffix.count + 1)
        guard value.hasSuffix("." + appGroupSuffix), !team.isEmpty,
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return value
    }

    public static func containerURL() -> URL? {
        guard let group = appGroupIdentifier else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    public static func fileURL() -> URL? { containerURL()?.appendingPathComponent(fileName) }
}

/// When the app should write the file and when it should ask WidgetKit to
/// reload, so neither the disk nor the widget refresh budget is hammered.
public struct WidgetWritePolicy: Equatable, Sendable {
    public var minimumWriteInterval: TimeInterval
    public var minimumReloadInterval: TimeInterval

    public init(minimumWriteInterval: TimeInterval = 15, minimumReloadInterval: TimeInterval = 5 * 60) {
        self.minimumWriteInterval = minimumWriteInterval
        self.minimumReloadInterval = minimumReloadInterval
    }

    public func shouldWrite(now: Date, lastWrite: Date?) -> Bool {
        guard let lastWrite else { return true }
        return now.timeIntervalSince(lastWrite) >= minimumWriteInterval || now < lastWrite
    }

    /// Reload promptly when the pressure level changes (the most important
    /// thing a glance should show) or the last reload is old enough.
    public func shouldReload(now: Date, lastReload: Date?, previousPressure: String?, pressure: String) -> Bool {
        guard let lastReload else { return true }
        if let previousPressure, previousPressure != pressure { return true }
        return now.timeIntervalSince(lastReload) >= minimumReloadInterval || now < lastReload
    }
}
