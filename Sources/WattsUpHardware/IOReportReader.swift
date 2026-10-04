import Foundation
import CSensors
import WattsUpCore

public struct EnergyChannelSample: Codable, Sendable {
    public let name: String
    public let group: String
    public let subgroup: String
    public let unit: String
    public let deltaValue: Int64
    public let elapsedSeconds: Double
    public let watts: Double?
}

public struct IOReportChannelDescriptor: Codable, Sendable {
    public let name: String
    public let group: String
    public let subgroup: String
    public let unit: String
}

final class IOReportReader {
    private var report: OpaquePointer?
    let connectionDiagnostic: String?
    private var buffer = [WUEnergyChannel](repeating: WUEnergyChannel(), count: 4_096)
    private(set) var availableChannels: [IOReportChannelDescriptor] = []
    /// True after a call that only captured the first energy baseline.
    private(set) var lastSampleWasBaseline = false

    init() {
        var error = [CChar](repeating: 0, count: 1_024)
        report = error.withUnsafeMutableBufferPointer { wu_ioreport_open($0.baseAddress, $0.count) }
        connectionDiagnostic = report == nil ? "IOReport: \(String(cString: error))" : nil
        var count = 0
        let result = buffer.withUnsafeMutableBufferPointer { channels in
            error.withUnsafeMutableBufferPointer { message in
                wu_ioreport_describe(channels.baseAddress, channels.count, &count, message.baseAddress, message.count)
            }
        }
        if result == 0 {
            availableChannels = buffer.prefix(count).map { channel in
                var channel = channel
                return IOReportChannelDescriptor(
                    name: Self.string(&channel.name), group: Self.string(&channel.group),
                    subgroup: Self.string(&channel.subgroup), unit: Self.string(&channel.unit))
            }
        }
    }
    deinit { if let report { wu_ioreport_close(report) } }

    private static func string<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
    }

    func sample() -> (channels: [EnergyChannelSample], diagnostics: [String]) {
        guard let report else { return ([], [connectionDiagnostic ?? "IOReport unavailable"]) }
        var count = 0
        var elapsed: Double = 0
        var error = [CChar](repeating: 0, count: 1_024)
        let result = buffer.withUnsafeMutableBufferPointer { channels in
            error.withUnsafeMutableBufferPointer { message in
                wu_ioreport_sample(report, channels.baseAddress, channels.count, &count, &elapsed,
                                   message.baseAddress, message.count)
            }
        }
        lastSampleWasBaseline = result == 1
        if result == 1 { return ([], ["IOReport baseline captured; energy-derived power becomes available at the next sample."]) }
        if result != 0 { return ([], ["IOReport: \(String(cString: error))"]) }
        let channels = buffer.prefix(count).map { channel -> EnergyChannelSample in
            var channel = channel
            let name = withUnsafePointer(to: &channel.name) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let group = withUnsafePointer(to: &channel.group) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let subgroup = withUnsafePointer(to: &channel.subgroup) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let unit = withUnsafePointer(to: &channel.unit) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            return EnergyChannelSample(name: name, group: group, subgroup: subgroup, unit: unit,
                                       deltaValue: channel.value, elapsedSeconds: elapsed,
                                       watts: SMCEnergyUnits.watts(delta: channel.value, unit: unit, elapsedSeconds: elapsed))
        }
        var diagnostics: [String] = []
        if channels.isEmpty { diagnostics.append("Energy Model subscription returned no channels.") }
        for channel in channels where channel.watts == nil {
            diagnostics.append("IOReport \(channel.name) is unknown: unsupported unit '\(channel.unit)', negative/reset delta, or invalid elapsed time.")
        }
        return (channels, diagnostics)
    }
}
