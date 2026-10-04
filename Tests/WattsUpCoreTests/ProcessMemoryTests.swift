import XCTest
@testable import WattsUpCore

final class ProcessMemoryTests: XCTestCase {
    // Captured from `top -l 1 -o mem -stats pid,command,mem,cmprs` on the Mac mini
    // (header trimmed), plus edge rows: equal mem/cmprs tokens, K/G/B units.
    let sample = """
    Processes: 791 total, 4 running, 787 sleeping, 4120 threads
    2026/10/03 23:25:01
    PhysMem: 23G used (3938M wired, 5040M compressor), 818M unused.
    VM: 416T vsize, 57G framework vsize, 219576(0) swapins, 656975(0) swapouts.

    PID    COMMAND          MEM   CMPRS
    632    WindowServer     2111M+ 846M
    3951   lldb-rpc-server  1498M 1495M
    70345  Claude Helper (R 1285M 501M
    1888   Maccy            698M  698M
    42023  WeChat           485M- 251M
    88     kernel_task      1.5G  0B
    501    mds_stores       940K  12K
    """

    func testUnitsAndTrendSuffixes() {
        XCTAssertEqual(TopMemoryParser.bytes("2111M+"), 2111 * 1_048_576)
        XCTAssertEqual(TopMemoryParser.bytes("485M-"), 485 * 1_048_576)
        XCTAssertEqual(TopMemoryParser.bytes("846M"), 846 * 1_048_576)
        XCTAssertEqual(TopMemoryParser.bytes("12K"), 12 * 1_024)
        XCTAssertEqual(TopMemoryParser.bytes("0B"), 0)
        XCTAssertEqual(TopMemoryParser.bytes("1.5G"), 1_610_612_736)
        XCTAssertEqual(TopMemoryParser.bytes("2T"), 2 * 1_099_511_627_776)
        XCTAssertEqual(TopMemoryParser.bytes("512"), 512)
        XCTAssertNil(TopMemoryParser.bytes("N/A"))
        XCTAssertNil(TopMemoryParser.bytes("-"))
        XCTAssertNil(TopMemoryParser.bytes("abcM"))
        XCTAssertNil(TopMemoryParser.bytes(""))
    }

    func testParsesRowsWithSpacesInCommandNames() {
        let rows = TopMemoryParser.parse(sample)
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[0], ProcessMemoryRow(pid: 632, name: "WindowServer",
                                                 memoryBytes: 2111 * 1_048_576, compressedBytes: 846 * 1_048_576))
        XCTAssertEqual(rows[2].name, "Claude Helper (R")
        XCTAssertEqual(rows[2].memoryBytes, 1285 * 1_048_576)
        // Equal tokens in the mem and cmprs columns must not confuse the parser.
        XCTAssertEqual(rows[3].name, "Maccy")
        XCTAssertEqual(rows[3].memoryBytes, rows[3].compressedBytes)
        XCTAssertEqual(rows[5].memoryBytes, 1_610_612_736)
        XCTAssertEqual(rows[5].compressedBytes, 0)
        XCTAssertEqual(rows[6].memoryBytes, 940 * 1_024)
    }

    func testHeaderAndSummaryLinesAreIgnored() {
        XCTAssertTrue(TopMemoryParser.parse("Processes: 1 total\nPhysMem: 23G used\n").isEmpty)
        let rows = TopMemoryParser.parse("PID COMMAND MEM CMPRS\nnot a row\n42 a b 1M 2M\n")
        XCTAssertEqual(rows.map(\.pid), [42])
        XCTAssertEqual(rows.first?.name, "a b")
    }

    func testRankingByMemoryAndCompressed() {
        let rows = TopMemoryParser.parse(sample)
        XCTAssertEqual(ProcessMemoryRanking.top(rows, by: .memory, limit: 3).map(\.pid), [632, 88, 3951])
        XCTAssertEqual(ProcessMemoryRanking.top(rows, by: .compressed, limit: 3).map(\.pid), [3951, 632, 1888])
        // Processes with no compressed memory are not listed under "压缩".
        XCTAssertFalse(ProcessMemoryRanking.top(rows, by: .compressed, limit: 10).contains { $0.pid == 88 })
        XCTAssertEqual(ProcessMemoryRanking.top(rows, by: .memory, limit: 10).count, 7)
        XCTAssertTrue(ProcessMemoryRanking.top(rows, by: .memory, limit: 0).isEmpty)
    }

    func testRankingIsStableForTies() {
        let rows = [ProcessMemoryRow(pid: 9, name: "b", memoryBytes: 10, compressedBytes: nil),
                    ProcessMemoryRow(pid: 3, name: "a", memoryBytes: 10, compressedBytes: nil)]
        XCTAssertEqual(ProcessMemoryRanking.top(rows, by: .memory, limit: 2).map(\.pid), [3, 9])
        // libproc fallback rows have no compressed data at all.
        XCTAssertTrue(ProcessMemoryRanking.top(rows, by: .compressed, limit: 2).isEmpty)
    }

    func testBestNameExpandsTruncatedTopNames() {
        XCTAssertEqual(TopMemoryParser.bestName(
            topName: "Claude Helper (R",
            executablePath: "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)",
            kernelName: "Claude Helper (Renderer)"), "Claude Helper (Renderer)")
        XCTAssertEqual(TopMemoryParser.bestName(topName: "QuarkCloudDrive ", executablePath: nil,
                                                kernelName: "QuarkCloudDrive Helper (Rendere"), "QuarkCloudDrive Helper (Rendere")
        // A path that does not extend the shown name is not trusted.
        XCTAssertEqual(TopMemoryParser.bestName(topName: "WindowServer", executablePath: "/usr/bin/other",
                                                kernelName: nil), "WindowServer")
    }
}
