import Foundation
import CSensors
import WattsUpCore

public struct SMCKeyReading: Codable, Sendable {
    public let index: UInt32?
    public let key: String
    public let type: String
    public let size: UInt32
    public let value: Double?
    public let rawHex: String
    public let error: String?
    public var isPowerRelated: Bool { key.hasPrefix("P") }
    public var isFloat: Bool { type == "flt " }
}

public struct SMCProbeReport: Codable, Sendable {
    public let timestamp: Date
    public let totalKeyCount: UInt32?
    public let keys: [SMCKeyReading]
    public let relevantKeys: [SMCKeyReading]
    public let diagnostics: [String]
}

final class SMCReader {
    private var connection: OpaquePointer?
    let connectionDiagnostic: String?

    init() {
        var error: Int32 = 0
        connection = wu_smc_open(&error)
        connectionDiagnostic = connection == nil ? "AppleSMC open failed: \(Self.errorDescription(error)). This can be a permission/sandbox denial; it does not establish that sensors are absent." : nil
    }

    deinit { if let connection { wu_smc_close(connection) } }

    static func errorDescription(_ error: Int32) -> String {
        String(format: "IOKit 0x%08X (%d)", UInt32(bitPattern: error), error)
    }

    func read(_ key: String, index: UInt32? = nil) -> SMCKeyReading {
        guard let connection, let identifier = SMCDecoding.fourCC(key) else {
            return SMCKeyReading(index: index, key: key, type: "", size: 0, value: nil, rawHex: "", error: connectionDiagnostic ?? "Invalid four-character key")
        }
        var reading = WUSMCValue()
        let error = wu_smc_read(connection, identifier, &reading)
        let type = SMCDecoding.fourCCString(reading.type)
        let bytes = withUnsafeBytes(of: reading.bytes) { Array($0.prefix(Int(min(reading.size, 32)))) }
        let decoded = error == 0 ? SMCDecoding.decode(type: type, bytes: bytes) : nil
        let description = error == 0 ? nil : "\(Self.errorDescription(error)); SMC result=\(reading.result), status=\(reading.status)"
        return SMCKeyReading(index: index, key: key, type: type, size: reading.size, value: decoded,
                             rawHex: bytes.map { String(format: "%02X", $0) }.joined(), error: description)
    }

    func probe() -> SMCProbeReport {
        var diagnostics: [String] = []
        if let connectionDiagnostic { diagnostics.append(connectionDiagnostic) }
        let countReading = read("#KEY")
        guard let connection, let numericCount = countReading.value,
              numericCount >= 0, numericCount <= 100_000, numericCount.rounded() == numericCount else {
            diagnostics.append("Cannot enumerate AppleSMC #KEY: \(countReading.error ?? "invalid/unsupported count payload")")
            return SMCProbeReport(timestamp: Date(), totalKeyCount: nil, keys: [countReading],
                                  relevantKeys: [], diagnostics: diagnostics)
        }
        let count = UInt32(numericCount)
        var keys: [SMCKeyReading] = []
        keys.reserveCapacity(Int(count))
        for index in 0..<count {
            var identifier: UInt32 = 0
            let error = wu_smc_key_at_index(connection, index, &identifier)
            if error != 0 {
                keys.append(SMCKeyReading(index: index, key: "", type: "", size: 0, value: nil,
                                          rawHex: "", error: "Key index enumeration: \(Self.errorDescription(error))"))
                continue
            }
            keys.append(read(SMCDecoding.fourCCString(identifier), index: index))
        }
        let failures = keys.filter { $0.error != nil }.count
        if failures > 0 { diagnostics.append("\(failures)/\(count) enumerated keys could not be read; per-key errors are preserved.") }
        return SMCProbeReport(timestamp: Date(), totalKeyCount: count, keys: keys,
                              relevantKeys: keys.filter { $0.isFloat || $0.isPowerRelated }, diagnostics: diagnostics)
    }
}
