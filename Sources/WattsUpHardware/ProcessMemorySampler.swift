import Darwin
import Foundation
import WattsUpCore

/// Per-process memory, like Activity Monitor's Memory tab. `top` is used
/// because it can read every process (including root-owned ones such as
/// WindowServer) and reports compressed memory; libproc's phys_footprint is a
/// fallback that only sees this user's processes. Call off the main thread.
public enum ProcessMemorySampler {
    public static func sample(timeout: TimeInterval = 4) -> ProcessMemoryReport {
        var topError: String?
        do {
            let output = try runTop(timeout: timeout)
            let rows = TopMemoryParser.parse(output)
            if !rows.isEmpty {
                return ProcessMemoryReport(rows: rows, source: "top")
            }
            topError = "top 没有返回可解析的进程行"
        } catch {
            topError = "\(error)"
        }
        let rows = libprocRows()
        return ProcessMemoryReport(rows: rows, source: "libproc",
                                   note: "\(topError ?? "top 不可用")；仅列出当前用户的进程，无压缩数据")
    }

    /// Fill in full names/paths for the rows that will actually be shown.
    public static func resolveNames(_ rows: [ProcessMemoryRow]) -> [ProcessMemoryRow] {
        rows.map { row in
            var row = row
            let path = executablePath(row.pid)
            row.path = path
            row.name = TopMemoryParser.bestName(topName: row.name, executablePath: path, kernelName: kernelName(row.pid))
            return row
        }
    }

    struct TopFailure: Error, CustomStringConvertible {
        let description: String
    }

    private static func runTop(timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/top")
        // One logging-mode sample, all processes, sorted by footprint.
        process.arguments = ["-l", "1", "-o", "mem", "-n", "600", "-stats", "pid,command,mem,cmprs"]
        process.environment = ["LC_ALL": "C", "LANG": "C", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw TopFailure(description: "top 退出状态 \(process.terminationStatus)")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func libprocRows() -> [ProcessMemoryRow] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        let count = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.size))
        }
        guard count > 0 else { return [] }
        var rows: [ProcessMemoryRow] = []
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }
            rows.append(ProcessMemoryRow(pid: pid, name: kernelName(pid) ?? "pid \(pid)",
                                         memoryBytes: info.ri_phys_footprint, compressedBytes: nil))
        }
        return rows
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func kernelName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
