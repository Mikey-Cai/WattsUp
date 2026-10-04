import Foundation

/// Pure byte conversions. SMC key/type identifiers are big-endian FourCC;
/// Apple Silicon `flt ` payloads are IEEE-754 little-endian, independently.
public enum SMCDecoding {
    public static func fourCC(_ string: String) -> UInt32? {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func fourCCString(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff),
                     UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? bytes.map { String(format: "\\x%02X", $0) }.joined()
    }

    public static func floatLittleEndian(_ bytes: [UInt8]) -> Double? {
        guard bytes.count == 4 else { return nil }
        let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) |
                   (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let value = Double(Float(bitPattern: bits))
        return value.isFinite ? value : nil
    }

    public static func unsignedBigEndian(_ bytes: [UInt8]) -> UInt64? {
        guard !bytes.isEmpty, bytes.count <= 8 else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    public static func decode(type: String, bytes: [UInt8]) -> Double? {
        if type == "flt " { return floatLittleEndian(bytes) }
        if ["ui8 ", "ui16", "ui32", "ui64"].contains(type) {
            let expected: [String: Int] = ["ui8 ": 1, "ui16": 2, "ui32": 4, "ui64": 8]
            guard bytes.count == expected[type] else { return nil }
            return unsignedBigEndian(bytes).map { Double($0) }
        }
        return nil
    }
}
