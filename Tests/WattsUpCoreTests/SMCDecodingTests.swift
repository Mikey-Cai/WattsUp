import XCTest
@testable import WattsUpCore

final class SMCDecodingTests: XCTestCase {
    func testIdentifiersUseBigEndian() {
        XCTAssertEqual(SMCDecoding.fourCC("PSTR"), 0x50535452)
        XCTAssertEqual(SMCDecoding.fourCCString(0x666c7420), "flt ")
        XCTAssertNil(SMCDecoding.fourCC("CPU"))
        XCTAssertNil(SMCDecoding.fourCC("电源键名"))
    }
    func testFloatPayloadIsLittleEndian() {
        XCTAssertEqual(SMCDecoding.floatLittleEndian([0, 0, 0xAC, 0x41]), 21.5)
        XCTAssertEqual(SMCDecoding.floatLittleEndian([0, 0, 0x80, 0xBF]), -1)
        XCTAssertEqual(SMCDecoding.floatLittleEndian([0, 0, 0, 0]), 0)
        XCTAssertNil(SMCDecoding.floatLittleEndian([0, 0, 0x80, 0x7F]))
        XCTAssertNil(SMCDecoding.floatLittleEndian([0, 0, 0xC0, 0x7F]))
        XCTAssertNil(SMCDecoding.floatLittleEndian([0, 0, 0]))
    }
    func testKeyCountIsUnsignedBigEndian() {
        XCTAssertEqual(SMCDecoding.decode(type: "ui32", bytes: [0, 0, 3, 0xE8]), 1_000)
        XCTAssertNil(SMCDecoding.decode(type: "ui32", bytes: [0, 1]))
        XCTAssertNil(SMCDecoding.decode(type: "sp78", bytes: [1, 2]))
    }
}
