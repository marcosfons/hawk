import Foundation

/// Everything measured at one instant, plus rates since the previous sample.
public struct Snapshot: Sendable {
    public var date = Date()
    public var cores: [Double] = []                 // 0...1 per logical core, E-cores first
    public var eCores = 0
    public var gpu: Double?
    public var temps = HIDSensors.Summary()
    public var gpuTemp: Double?                     // hottest SMC Tg* sensor
    public var fans: [SMC.Fan] = []
    public var systemPower: Double?                 // SMC PSTR: whole Mac, watts, ~1 s fresh
    public var memory: MemoryStats?
    public var swapInRate = 0.0, swapOutRate = 0.0  // bytes/s
    public var volumes: [VolumeUsage] = []
    public var disks: [(name: String, read: Double, write: Double)] = []        // bytes/s
    public var interfaces: [(name: String, rx: Double, tx: Double)] = []        // bytes/s
    public var power: PowerInfo?

    public init() {}

    public var cpuTotal: Double { Self.mean(cores) ?? 0 }
    public var eUsage: Double { Self.mean(Array(cores.prefix(eCores))) ?? 0 }
    public var pUsage: Double { Self.mean(Array(cores.dropFirst(eCores))) ?? 0 }
    public var socMax: Double? { temps.soc.max() }
    public var socAvg: Double? { Self.mean(temps.soc) }
    public var ssdTemp: Double? { temps.ssd.max() }
    public var batteryTemp: Double? { temps.battery.max() }
    public var diskRead: Double { disks.map(\.read).reduce(0, +) }
    public var diskWrite: Double { disks.map(\.write).reduce(0, +) }
    /// Physical interfaces only: VPN tunnels carry the same bytes again.
    public var netRx: Double { interfaces.filter { $0.name.hasPrefix("en") }.map(\.rx).reduce(0, +) }
    public var netTx: Double { interfaces.filter { $0.name.hasPrefix("en") }.map(\.tx).reduce(0, +) }
    public var curveTemps: CurveTemps { CurveTemps(soc: socMax, ssd: ssdTemp, battery: batteryTemp) }

    static func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
}

/// Collects snapshots. Not thread-safe: own it from one thread or actor.
/// Load, fans, power and I/O are read every call. Temperatures (slow to change, and
/// the costliest read: one round trip per sensor) every 3 s; the battery (whose gauge
/// only refreshes every 30-60 s) every 2 s; volume capacities every 30 s.
public final class Sampler {
    private let smc = SMC()
    private let hid = HIDSensors()
    private let cpu = CPUMonitor()
    /// SMC keys of the GPU temperature sensors. Finding them means reading every SMC key
    /// (a third of a second), so callers may cache them and pass them back in.
    public private(set) var gpuKeys: [String]
    private var lastTime = Date()
    private var interfaceNames: [UInt16: String] = [:]
    private var lastDisk = diskIOCounters(), lastNet: [String: (rx: UInt64, tx: UInt64)] = [:]
    private var lastSwap: (UInt64, UInt64)
    private var temps = HIDSensors.Summary(), gpuTemp: Double?, tempsAt = Date.distantPast
    private var power: PowerInfo?, powerAt = Date.distantPast
    private var macOSHealth: Int?, healthAt = Date.distantPast
    private var volumes: [VolumeUsage] = [], volumesAt = Date.distantPast

    /// `gpuKeys`: a cached result of `discoverGPUKeys()`; nil discovers them now.
    /// `batteryHealth`: a cached macOS Maximum Capacity; nil asks macOS on the first sample.
    public init(gpuKeys: [String]? = nil, batteryHealth: Int? = nil) {
        lastSwap = memoryStats().map { ($0.swapIns, $0.swapOuts) } ?? (0, 0)
        lastNet = networkCounters(names: &interfaceNames)
        self.gpuKeys = []
        if let batteryHealth { macOSHealth = batteryHealth; healthAt = Date() }
        if let gpuKeys { self.gpuKeys = gpuKeys } else { discoverGPUKeys() }
    }

    /// GPU sensors differ per chip, so find the Tg* keys that report plausible values.
    public func discoverGPUKeys() {
        let smc = self.smc
        gpuKeys = smc?.allKeys().filter { k in
            k.hasPrefix("Tg") && (smc?.number(k)).map { $0 > 10 && $0 < 120 } == true
        } ?? []
    }

    /// macOS's battery Maximum Capacity as last read, for callers that cache it.
    public var batteryHealth: Int? { macOSHealth }

    public func sample() -> Snapshot {
        let now = Date(), dt = max(now.timeIntervalSince(lastTime), 0.001)
        lastTime = now
        var s = Snapshot()
        s.date = now
        s.cores = cpu.sample(); s.eCores = cpu.eCores; s.gpu = gpuUsage()
        if now.timeIntervalSince(tempsAt) >= 3 {
            temps = hid.summary()
            gpuTemp = gpuKeys.compactMap { smc?.number($0) }.filter { $0 > 10 && $0 < 120 }.max()
            tempsAt = now
        }
        s.temps = temps
        s.gpuTemp = gpuTemp
        s.fans = smc?.fans() ?? []
        s.systemPower = smc?.number("PSTR")

        s.memory = memoryStats()
        if let m = s.memory {
            let page = Double(getpagesize())
            s.swapInRate = Double(m.swapIns &- lastSwap.0) * page / dt
            s.swapOutRate = Double(m.swapOuts &- lastSwap.1) * page / dt
            lastSwap = (m.swapIns, m.swapOuts)
        }

        let d = diskIOCounters()
        s.disks = d.keys.sorted().compactMap { k in
            guard let p = lastDisk[k], let c = d[k] else { return nil }
            return (k, Double(c.read &- p.read) / dt, Double(c.write &- p.write) / dt)
        }
        lastDisk = d

        let n = networkCounters(names: &interfaceNames)
        s.interfaces = n.keys.sorted().compactMap { k in
            guard let p = lastNet[k], let c = n[k], c.rx > 0 || c.tx > 0 else { return nil }
            return (k, Double(c.rx &- p.rx) / dt, Double(c.tx &- p.tx) / dt)
        }
        lastNet = n

        if now.timeIntervalSince(powerAt) >= 2 { power = powerInfo(); powerAt = now }
        if now.timeIntervalSince(healthAt) >= 1800 { macOSHealth = macOSBatteryHealth(); healthAt = now }
        power?.macOSHealth = macOSHealth
        if now.timeIntervalSince(volumesAt) >= 30 { volumes = HawkKit.volumes(); volumesAt = now }
        s.power = power
        s.volumes = volumes
        return s
    }
}
