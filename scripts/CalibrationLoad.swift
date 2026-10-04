// Local, bounded calibration stimuli. Compile with the installed Swift compiler.
// No UI, networking, privileges, persistent files, or background service.
import Darwin
import Foundation
import Metal

private var receivedSignal: Int32 = 0
private func signalHandler(_ number: Int32) { receivedSignal = number }

private struct Options {
    let mode: String
    let seconds: Double
    let bytes: Int
    let diskFile: String?
    let readyFile: String?

    init() throws {
        var values: [String: String] = [:]
        let args = Array(CommandLine.arguments.dropFirst())
        if args == ["--help"] {
            print("CalibrationLoad --mode gpu|memory|disk --seconds 1...45 --bytes 16777216...268435456 [--disk-file NEW_PATH] [--ready-file PATH]")
            exit(0)
        }
        guard args.count % 2 == 0 else { throw Failure("Arguments must be key/value pairs") }
        for i in stride(from: 0, to: args.count, by: 2) {
            guard ["--mode", "--seconds", "--bytes", "--disk-file", "--ready-file"].contains(args[i]),
                  values[args[i]] == nil else { throw Failure("Unknown or repeated argument: \(args[i])") }
            values[args[i]] = args[i + 1]
        }
        guard let mode = values["--mode"], ["gpu", "memory", "disk"].contains(mode),
              let seconds = Double(values["--seconds"] ?? "20"), seconds.isFinite, seconds >= 1, seconds <= 45,
              let bytes = Int(values["--bytes"] ?? "134217728"), bytes >= 16 * 1024 * 1024,
              bytes <= 256 * 1024 * 1024, bytes % 4096 == 0 else {
            throw Failure("Invalid mode, duration (1...45 seconds), or size (16...256 MB, 4096-byte aligned)")
        }
        if mode == "disk" {
            guard bytes <= 128 * 1024 * 1024, let path = values["--disk-file"], path.hasPrefix("/") else {
                throw Failure("Disk stimulus requires a new absolute --disk-file and at most 128 MB")
            }
        }
        self.mode = mode
        self.seconds = seconds
        self.bytes = bytes
        self.diskFile = values["--disk-file"]
        self.readyFile = values["--ready-file"]
    }
}

private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

private func emit(_ object: [String: Any]) throws {
    let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(bytes)
    FileHandle.standardOutput.write(Data([10]))
}

private final class Work {
    let options: Options
    let started = ProcessInfo.processInfo.systemUptime
    var readyAt: Double?
    var iterations: UInt64 = 0
    var bytesMoved: UInt64 = 0
    var checksum: Double = 0
    var metadata: [String: Any] = [:]

    init(_ options: Options) { self.options = options }

    var running: Bool {
        receivedSignal == 0 && ProcessInfo.processInfo.systemUptime - started < options.seconds
    }

    func didWork(bytes: UInt64) throws {
        iterations += 1
        bytesMoved += bytes
        if readyAt == nil {
            let now = ProcessInfo.processInfo.systemUptime
            readyAt = now
            let record: [String: Any] = ["event": "ready", "mode": options.mode, "pid": getpid(),
                "uptimeSeconds": now, "timestamp": ISO8601DateFormatter().string(from: Date()),
                "firstIterationCompleted": true, "metadata": metadata]
            if let file = options.readyFile {
                // Python owns the private directory; no file is written elsewhere.
                try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]).write(to: URL(fileURLWithPath: file), options: .atomic)
            }
            try emit(record)
        }
    }

    func finish() throws {
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try emit(["event": "finished", "mode": options.mode, "pid": getpid(),
            "elapsedSeconds": elapsed, "iterations": iterations, "bytesMoved": bytesMoved,
            "approxBytesPerSecond": elapsed > 0 ? Double(bytesMoved) / elapsed : 0,
            "checksum": checksum, "signal": receivedSignal, "metadata": metadata])
    }
}

private func memoryLoad(_ work: Work) throws {
    // Two streams jointly use exactly --bytes; copies exceed typical CPU caches.
    let count = work.options.bytes / 2
    let first = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4096)
    let second = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 4096)
    defer { first.deallocate(); second.deallocate() }
    memset(first, 0xA5, count)
    memset(second, 0x5A, count)
    work.metadata = ["allocationBytes": work.options.bytes, "streamBytes": count, "method": "libc memcpy; alternating source/destination; checksum"]
    var source = first
    var target = second
    while work.running {
        memcpy(target, source, count)
        // Change data and observe it so this is real memory traffic under -O.
        let word = target.assumingMemoryBound(to: UInt64.self)
        word.pointee = word.pointee &+ work.iterations &+ 1
        work.checksum = Double(word.pointee & 0xFFFF_FFFF)
        swap(&source, &target)
        try work.didWork(bytes: UInt64(count) * 2)
    }
}

private func gpuLoad(_ work: Work) throws {
    guard let device = MTLCreateSystemDefaultDevice() else { throw Failure("No usable Metal device; GPU stimulus was not run") }
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void calibrate(device const float *input [[buffer(0)]],
                          device float *output [[buffer(1)]], uint i [[thread_position_in_grid]]) {
        float x = input[i];
        for (uint k = 0; k < 512; ++k) { x = fma(x, 0.99991f, 0.000031f); }
        output[i] = x;
    }
    """
    let library = try device.makeLibrary(source: source, options: nil)
    guard let function = library.makeFunction(name: "calibrate"), let queue = device.makeCommandQueue() else {
        throw Failure("Could not create Metal compute function/queue")
    }
    let pipeline = try device.makeComputePipelineState(function: function)
    let count = 1_048_576
    let length = count * MemoryLayout<Float>.stride
    guard let first = device.makeBuffer(length: length, options: .storageModeShared),
          let second = device.makeBuffer(length: length, options: .storageModeShared) else {
        throw Failure("Metal buffer allocation failed")
    }
    first.contents().assumingMemoryBound(to: Float.self).initialize(repeating: 0.25, count: count)
    second.contents().assumingMemoryBound(to: Float.self).initialize(repeating: .nan, count: count)
    work.metadata = ["device": device.name, "allocationBytes": length * 2, "threadCount": count,
        "fmaIterationsPerThread": 512, "method": "Metal compute; GPU command completion and finite result checked"]
    var input = first
    var output = second
    while work.running {
        guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw Failure("Metal command creation failed")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(input, offset: 0, index: 0)
        encoder.setBuffer(output, offset: 0, index: 1)
        let width = min(256, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw Failure("Metal execution failed: \(command.error?.localizedDescription ?? "unknown command error")") }
        let result = output.contents().assumingMemoryBound(to: Float.self).pointee
        guard result.isFinite else { throw Failure("Metal result was not finite") }
        work.checksum = Double(result)
        swap(&input, &output)
        try work.didWork(bytes: UInt64(length) * 2)
    }
}

private func diskLoad(_ work: Work) throws {
    guard let path = work.options.diskFile else { throw Failure("Missing disk file") }
    // Never opens an existing file, never traverses a final symlink.
    let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw Failure("Exclusive disk file creation failed: \(String(cString: strerror(errno)))") }
    defer { _ = close(fd); _ = unlink(path) }
    guard fcntl(fd, F_NOCACHE, 1) == 0 else { throw Failure("F_NOCACHE failed: \(String(cString: strerror(errno)))") }
    let chunk = 4 * 1024 * 1024
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
    defer { buffer.deallocate() }
    arc4random_buf(buffer, chunk)
    work.metadata = ["fileBytes": work.options.bytes, "bufferBytes": chunk, "noCache": true,
        "fsyncEachWritePass": true, "method": "bounded pwrite + fsync + pread; F_NOCACHE; exclusive file removed on exit"]

    func transfer(write: Bool) throws -> UInt64 {
        var offset = 0
        while offset < work.options.bytes && work.running {
            let wanted = min(chunk, work.options.bytes - offset)
            var done = 0
            while done < wanted && work.running {
                let position = off_t(offset + done)
                let transferred = write ? pwrite(fd, buffer.advanced(by: done), wanted - done, position)
                    : pread(fd, buffer.advanced(by: done), wanted - done, position)
                if transferred < 0 && errno == EINTR { continue }
                guard transferred > 0 else { throw Failure("Disk \(write ? "write" : "read") failed: \(String(cString: strerror(errno)))") }
                done += transferred
            }
            offset += done
        }
        return UInt64(offset)
    }

    while work.running {
        let written = try transfer(write: true)
        guard fsync(fd) == 0 || (errno == EINTR && receivedSignal != 0) else { throw Failure("fsync failed: \(String(cString: strerror(errno)))") }
        if !work.running { work.bytesMoved += written; break }
        let read = try transfer(write: false)
        work.checksum = Double(buffer.assumingMemoryBound(to: UInt32.self).pointee)
        if written == UInt64(work.options.bytes) && read == UInt64(work.options.bytes) {
            try work.didWork(bytes: written + read)
        } else {
            work.bytesMoved += written + read
        }
    }
}

do {
    signal(SIGINT, signalHandler)
    signal(SIGTERM, signalHandler)
    signal(SIGHUP, signalHandler)
    let work = Work(try Options())
    switch work.options.mode {
    case "gpu": try gpuLoad(work)
    case "memory": try memoryLoad(work)
    case "disk": try diskLoad(work)
    default: throw Failure("Unsupported mode")
    }
    guard work.iterations > 0 else { throw Failure("Stimulus did not complete a work iteration") }
    try work.finish()
} catch {
    // Explicit failure; never substitute a CPU loop for an unavailable GPU.
    try? emit(["event": "error", "message": String(describing: error), "pid": getpid(), "signal": receivedSignal])
    exit(1)
}
