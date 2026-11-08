import Foundation

/// What a device is doing now (requirements 2.4): CPU per core and frequency, RAM,
/// swap and zram, network rates, temperatures, top processes.
public struct LiveStats: Sendable, Equatable {
    public struct Process: Sendable, Equatable {
        public let pid: Int
        public let cpu: Double
        public let resident: String
        public let name: String
    }

    /// Busy share per core, 0...1, since the previous reading.
    public var cores: [Double] = []
    public var total: Double?
    public var frequencyMHz: [Int: Int] = [:]
    public var memTotalKB: Int?
    public var memAvailableKB: Int?
    public var swapTotalKB: Int?
    public var swapFreeKB: Int?
    /// Bytes per second, every interface but loopback.
    public var rxRate: Double?
    public var txRate: Double?
    public var temperatures: [(name: String, celsius: Double)] = []
    public var top: [Process] = []

    public init() {}

    public static func == (a: LiveStats, b: LiveStats) -> Bool {
        a.cores == b.cores && a.total == b.total && a.frequencyMHz == b.frequencyMHz && a.memAvailableKB == b.memAvailableKB
            && a.swapFreeKB == b.swapFreeKB && a.rxRate == b.rxRate && a.txRate == b.txRate
            && a.temperatures.map(\.celsius) == b.temperatures.map(\.celsius) && a.top == b.top
    }
}

/// Reads LiveStats one batch per tick (3 s while the Live page is shown) and keeps
/// the previous counters to turn them into rates. Measured on a phone: the /proc
/// reads cost about 20 ms of CPU, thermalservice 20 ms, top 100 ms; so temperatures
/// come every third tick and top processes every tenth, about 1.6% of a core.
public struct LiveSampler: Sendable {
    private var previousCPU: [[Int64]] = []
    private var previousNet: (rx: Int64, tx: Int64, at: TimeInterval)?
    private var last = LiveStats()
    public private(set) var tick = 0

    public init() {}

    public static func parts(tick: Int) -> [String: String] {
        var p = [
            "proc": "cat /proc/stat /proc/meminfo /proc/net/dev",
            "freq": "grep -H . /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null",
        ]
        if tick % 3 == 0 { p["thermal"] = "dumpsys thermalservice 2>/dev/null | grep -A30 'Current temperatures from HAL' | grep -m 16 'Temperature{'" }
        if tick % 10 == 0 { p["top"] = "top -b -n 1 -m 8 -o PID,%CPU,RES,NAME" }
        return p
    }

    public var nextParts: [String: String] { Self.parts(tick: tick) }

    /// One tick's output, at `now` (seconds, monotonic).
    public mutating func update(_ parts: [String: String], now: TimeInterval) -> LiveStats {
        defer { tick += 1 }
        var s = last
        let proc = (parts["proc"] ?? "").prefix(1 << 20)
        var cpu: [[Int64]] = []
        var rx: Int64 = 0, tx: Int64 = 0, sawNet = false
        for line in proc.split(whereSeparator: \.isNewline).prefix(5000) {
            if line.hasPrefix("cpu") {
                let f = line.split(separator: " ")
                // "cpu" is the total; "cpuN" one core.
                cpu.append(f.dropFirst().prefix(8).compactMap { Int64($0) })
            } else if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                let value = line[line.index(after: colon)...].split(separator: " ")
                switch key {
                case "MemTotal": s.memTotalKB = value.first.flatMap { Int($0) }
                case "MemAvailable": s.memAvailableKB = value.first.flatMap { Int($0) }
                case "SwapTotal": s.swapTotalKB = value.first.flatMap { Int($0) }
                case "SwapFree": s.swapFreeKB = value.first.flatMap { Int($0) }
                default:
                    // /proc/net/dev: "  wlan0: <rx bytes> ... <tx bytes at field 9>"
                    if key != "lo", value.count >= 9, let r = Int64(value[0]), let t = Int64(value[8]), !key.contains(" ") {
                        rx += r
                        tx += t
                        sawNet = true
                    }
                }
            }
        }
        if cpu.count >= 2 {
            if previousCPU.count == cpu.count {
                let shares = zip(cpu, previousCPU).map { Self.busy($0, $1) }
                s.total = shares[0]
                s.cores = Array(shares.dropFirst()).map { $0 ?? 0 }
            }
            previousCPU = cpu
        }
        if sawNet {
            if let p = previousNet, now > p.at, rx >= p.rx, tx >= p.tx {
                s.rxRate = Double(rx - p.rx) / (now - p.at)
                s.txRate = Double(tx - p.tx) / (now - p.at)
            }
            previousNet = (rx, tx, now)
        }
        if let freq = parts["freq"] {
            var f: [Int: Int] = [:]
            for line in freq.split(whereSeparator: \.isNewline).prefix(64) {
                // ".../cpu3/cpufreq/scaling_cur_freq:1959000" (kHz)
                guard let m = line.firstMatch(of: /\/cpu(\d+)\//), let core = Int(m.1), let colon = line.lastIndex(of: ":"),
                      let khz = Int(line[line.index(after: colon)...]) else { continue }
                f[core] = khz / 1000
            }
            s.frequencyMHz = f
        }
        if let thermal = parts["thermal"] {
            s.temperatures = thermal.split(whereSeparator: \.isNewline).prefix(16).compactMap { line in
                guard let v = Self.field("mValue=", line).flatMap(Double.init), let n = Self.field("mName=", line), v > -50, v < 200 else { return nil }
                return (String(n.prefix(24)), v)
            }
        }
        if let top = parts["top"] {
            s.top = top.split(whereSeparator: \.isNewline).compactMap { line in
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard f.count >= 4, let pid = Int(f[0]), let c = Double(f[1]) else { return nil }
                return LiveStats.Process(pid: pid, cpu: c, resident: String(f[2]), name: String(f[3...].joined(separator: " ").prefix(64)))
            }.prefix(8).map { $0 }
        }
        last = s
        return s
    }

    /// Busy share between two /proc/stat rows: everything but idle and iowait.
    static func busy(_ now: [Int64], _ before: [Int64]) -> Double? {
        guard now.count >= 5, before.count >= 5 else { return nil }
        let d = zip(now, before).map { $0 - $1 }
        let total = d.reduce(0, +)
        guard total > 0, d.allSatisfy({ $0 >= 0 }) else { return nil }
        return Double(total - d[3] - d[4]) / Double(total)
    }

    static func field(_ key: String, _ line: Substring) -> String? {
        guard let r = line.range(of: key) else { return nil }
        return String(line[r.upperBound...].prefix { $0 != "," && $0 != "}" })
    }
}
