import Foundation

/// One row of a per-process memory listing. `memoryBytes` is the process's
/// physical footprint (the "Memory" column in Activity Monitor and `top`'s MEM).
public struct ProcessMemoryRow: Equatable, Sendable, Codable {
    public let pid: Int32
    public var name: String
    public var path: String?
    public let memoryBytes: UInt64
    /// nil when the source cannot read compressed memory (libproc fallback).
    public let compressedBytes: UInt64?

    public init(pid: Int32, name: String, path: String? = nil, memoryBytes: UInt64, compressedBytes: UInt64?) {
        self.pid = pid
        self.name = name
        self.path = path
        self.memoryBytes = memoryBytes
        self.compressedBytes = compressedBytes
    }
}

public enum ProcessMemorySort: String, Sendable, Codable {
    case memory
    case compressed
}

public struct ProcessMemoryReport: Sendable, Codable {
    public let timestamp: Date
    public let rows: [ProcessMemoryRow]
    /// "top" or "libproc".
    public let source: String
    public let note: String?

    public init(timestamp: Date = Date(), rows: [ProcessMemoryRow], source: String, note: String? = nil) {
        self.timestamp = timestamp
        self.rows = rows
        self.source = source
        self.note = note
    }

    public func top(by sort: ProcessMemorySort, limit: Int = 10) -> [ProcessMemoryRow] {
        ProcessMemoryRanking.top(rows, by: sort, limit: limit)
    }
}

public enum ProcessMemoryRanking {
    /// Highest first; ties keep a stable pid order so the list does not shuffle.
    public static func top(_ rows: [ProcessMemoryRow], by sort: ProcessMemorySort, limit: Int) -> [ProcessMemoryRow] {
        guard limit > 0 else { return [] }
        func key(_ row: ProcessMemoryRow) -> UInt64 {
            switch sort {
            case .memory: return row.memoryBytes
            case .compressed: return row.compressedBytes ?? 0
            }
        }
        let candidates = sort == .compressed ? rows.filter { ($0.compressedBytes ?? 0) > 0 } : rows
        return Array(candidates.sorted { a, b in
            let ka = key(a), kb = key(b)
            return ka != kb ? ka > kb : a.pid < b.pid
        }.prefix(limit))
    }
}

/// Parser for `top -l 1 -stats pid,command,mem,cmprs` output.
/// The command column is fixed-width (truncated to 16 characters) and may
/// contain spaces, so a row is read as: pid, command…, mem, cmprs.
public enum TopMemoryParser {
    /// `top` prints binary units with an optional trend suffix: "2111M+", "846M",
    /// "0B", "12K", "1.5G", "3T". Unknown or malformed tokens return nil.
    public static func bytes(_ token: String) -> UInt64? {
        var text = token.trimmingCharacters(in: .whitespaces)
        while let last = text.last, "+-*".contains(last) { text.removeLast() }
        guard !text.isEmpty else { return nil }
        let multiplier: Double
        switch text.last {
        case "B", "b": multiplier = 1; text.removeLast()
        case "K", "k": multiplier = 1_024; text.removeLast()
        case "M", "m": multiplier = 1_048_576; text.removeLast()
        case "G", "g": multiplier = 1_073_741_824; text.removeLast()
        case "T", "t": multiplier = 1_099_511_627_776; text.removeLast()
        default: multiplier = 1
        }
        guard !text.isEmpty, text.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Double(text), value.isFinite, value >= 0 else { return nil }
        let result = value * multiplier
        guard result < Double(UInt64.max) else { return nil }
        return UInt64(result.rounded())
    }

    public static func parse(_ output: String) -> [ProcessMemoryRow] {
        var rows: [ProcessMemoryRow] = []
        var inTable = false
        for rawLine in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("PID") && trimmed.contains("COMMAND") {
                inTable = true
                continue
            }
            guard inTable, !trimmed.isEmpty else { continue }
            if let row = parseRow(trimmed) { rows.append(row) }
        }
        return rows
    }

    private static let rowPattern = try! NSRegularExpression(pattern: #"^\s*(\d+)\s+(.+?)\s+(\S+)\s+(\S+)\s*$"#)

    static func parseRow(_ line: String) -> ProcessMemoryRow? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = rowPattern.firstMatch(in: line, range: range), match.numberOfRanges == 5,
              let pidRange = Range(match.range(at: 1), in: line),
              let commandRange = Range(match.range(at: 2), in: line),
              let memRange = Range(match.range(at: 3), in: line),
              let cmprsRange = Range(match.range(at: 4), in: line),
              let pid = Int32(line[pidRange]), pid >= 0,
              let memory = bytes(String(line[memRange])) else { return nil }
        let cmprsToken = String(line[cmprsRange])
        let compressed = bytes(cmprsToken)
        // A non-numeric last column means this is not a pid/command/mem/cmprs row.
        guard compressed != nil || cmprsToken == "N/A" || cmprsToken == "-" else { return nil }
        let command = line[commandRange].trimmingCharacters(in: .whitespaces)
        guard !command.isEmpty else { return nil }
        return ProcessMemoryRow(pid: pid, name: command, memoryBytes: memory, compressedBytes: compressed)
    }

    /// `top` truncates names to 16 characters. Prefer the executable's full
    /// file name (or the kernel's 32-character name) when it extends the
    /// truncated one; otherwise keep what top printed.
    public static func bestName(topName: String, executablePath: String?, kernelName: String?) -> String {
        let shown = topName.trimmingCharacters(in: .whitespaces)
        if let executablePath, !executablePath.isEmpty {
            let base = (executablePath as NSString).lastPathComponent
            if !base.isEmpty, base.hasPrefix(shown) || shown.isEmpty { return base }
        }
        if let kernelName, !kernelName.isEmpty, kernelName.hasPrefix(shown), kernelName.count > shown.count {
            return kernelName
        }
        return shown.isEmpty ? (kernelName ?? "") : shown
    }
}
