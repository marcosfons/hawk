import Foundation

/// One moment of a performance capture (requirements 9).
public struct PerfSample: Sendable, Equatable {
    /// Seconds since the capture started.
    public let t: Double
    /// Highest and average current frequency across cores.
    public var maxMHz: Int?
    public var avgMHz: Int?
    /// Pressure stall: share of the last 10 s some task waited on CPU, memory, I/O.
    public var cpuPressure: Double?
    public var memoryPressure: Double?
    public var ioPressure: Double?
    /// 0 none ... 6 shutdown (PowerManager's thermal status).
    public var thermal: Int?
    public var pssKB: Int?

    public init(t: Double) { self.t = t }
}

/// Frame timing of an app between a reset and now (`dumpsys gfxinfo <pkg>`).
public struct FrameStats: Sendable, Equatable {
    public var total: Int?
    public var janky: Int?
    public var p50: Double?
    public var p90: Double?
    public var p95: Double?
    public var p99: Double?
    public var jankyShare: Double? { total.flatMap { t in janky.map { t > 0 ? Double($0) / Double(t) : 0 } } }

    public init() {}

    public static func parse(_ text: String) -> FrameStats {
        var s = FrameStats()
        for line in text.prefix(512 * 1024).split(whereSeparator: \.isNewline).prefix(4000) {
            let t = line.trimmingCharacters(in: .whitespaces)
            func number(after key: String) -> Double? {
                guard t.hasPrefix(key) else { return nil }
                return Double(t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).prefix { $0.isNumber || $0 == "." })
            }
            // The first block is the app's own (later ones are per window); keep the first value.
            if s.total == nil, let v = number(after: "Total frames rendered:") { s.total = Int(v) }
            if s.janky == nil, let v = number(after: "Janky frames:") { s.janky = Int(v) }
            if s.p50 == nil, let v = number(after: "50th percentile:") { s.p50 = v }
            if s.p90 == nil, let v = number(after: "90th percentile:") { s.p90 = v }
            if s.p95 == nil, let v = number(after: "95th percentile:") { s.p95 = v }
            if s.p99 == nil, let v = number(after: "99th percentile:") { s.p99 = v }
        }
        return s
    }
}

/// What a capture reads each second, and its parsers. A capture is an explicit
/// heavy action: it may cost more than the phone budget while it runs, and stops
/// on its own after `maxSeconds`.
public enum PerformanceCapture {
    public static let maxSeconds = 600

    public static func parts(tick: Int, package: String?) -> [String: String] {
        var p = [
            "psi": "cat /proc/pressure/cpu /proc/pressure/memory /proc/pressure/io 2>/dev/null",
            "freq": "grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null",
        ]
        if tick % 5 == 0 {
            p["thermal"] = "dumpsys thermalservice 2>/dev/null | grep -m1 'Thermal Status'"
            if let pkg = package.flatMap(ShellQuote.package) { p["mem"] = "dumpsys meminfo \(pkg) 2>/dev/null | grep -m1 'TOTAL PSS'" }
        }
        return p
    }

    /// The reset at the start and the read at the end of a capture.
    public static func gfxinfo(_ package: String, reset: Bool) -> String? {
        ShellQuote.package(package).map { "dumpsys gfxinfo \($0)\(reset ? " reset" : "")" }
    }

    public static func sample(_ p: [String: String], t: Double) -> PerfSample {
        var s = PerfSample(t: t)
        // "some avg10=4.25 ...": three files, cpu then memory then io, "some" first in each.
        let some = (p["psi"] ?? "").split(whereSeparator: \.isNewline).filter { $0.hasPrefix("some") }.compactMap { line -> Double? in
            guard let r = line.range(of: "avg10=") else { return nil }
            return Double(line[r.upperBound...].prefix { $0.isNumber || $0 == "." }).map { $0 / 100 }
        }
        if some.count >= 1 { s.cpuPressure = some[0] }
        if some.count >= 2 { s.memoryPressure = some[1] }
        if some.count >= 3 { s.ioPressure = some[2] }
        let freqs = (p["freq"] ?? "").split(whereSeparator: \.isNewline).compactMap { line -> Int? in
            line.lastIndex(of: ":").flatMap { Int(line[line.index(after: $0)...]) }.map { $0 / 1000 }
        }
        if !freqs.isEmpty {
            s.maxMHz = freqs.max()
            s.avgMHz = freqs.reduce(0, +) / freqs.count
        }
        if let th = p["thermal"], let colon = th.lastIndex(of: ":") { s.thermal = Int(th[th.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let mem = p["mem"] {
            // "TOTAL PSS:   123456   TOTAL RSS: ..." or "TOTAL   123456 ..." on older versions.
            s.pssKB = mem.split(separator: " ").lazy.compactMap { Int($0) }.first
        }
        return s
    }

    /// Perfetto trace for deeper analysis, written where the shell may write, pulled,
    /// then deleted on the phone.
    public static let traceRemote = "/data/misc/perfetto-traces/hawk.perfetto-trace"
    public static func traceCommand(seconds: Int) -> String {
        "perfetto -o \(traceRemote) -t \(max(1, min(seconds, 60)))s sched freq idle am wm gfx view binder_driver hal dalvik input res memory 2>&1"
    }
}

public enum Timeline {
    /// At most `max` points: consecutive samples averaged into buckets, so a long
    /// capture draws as fast as a short one (Hawk's charts cap their points).
    public static func downsample(_ points: [(t: Double, v: Double)], max: Int) -> [(t: Double, v: Double)] {
        guard points.count > max, max > 0 else { return points }
        let size = Double(points.count) / Double(max)
        return (0..<max).compactMap { i in
            let lo = Int(Double(i) * size), hi = min(points.count, Int(Double(i + 1) * size))
            guard lo < hi else { return nil }
            let slice = points[lo..<hi]
            return (slice.map(\.t).reduce(0, +) / Double(slice.count), slice.map(\.v).reduce(0, +) / Double(slice.count))
        }
    }
}
