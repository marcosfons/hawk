import Foundation

public struct AlertSettings: Codable, Sendable, Equatable {
    public var notify = true                 // also post macOS notifications
    public var lowDisk = true
    public var lowDiskGB = 15.0
    public var memoryPressure = true
    public var pressure = 0.8                // sustained 2 min
    public var swapGrowth = true
    public var swapGBPer10Min = 2.0
    public var leaks = true
    public var leakMBPerMinute = 100.0       // sustained 5 min
    public var hotChip = true
    public var chipCelsius = 95.0            // sustained 1 min
    public var batteryDrain = true
    public var appWatts = 5.0                // one app, on battery, sustained 5 min
    public var hotBattery = true
    public var batteryCelsius = 40.0         // sustained 1 min
    public init() {}
}

public struct FanAlert: Sendable, Identifiable, Equatable {
    public let id = UUID()
    public let key: String
    public let title: String
    public let body: String
    public let date: Date
    /// What raised it: the Mac (fans, temperature, memory...) or an Android device.
    public var kind: Kind = .mac

    public enum Kind: Sendable, Equatable {
        case mac
        case androidANR
        case androidCrash
    }

    public init(key: String, title: String, body: String, date: Date = Date(), kind: Kind = .mac) {
        self.key = key; self.title = title; self.body = body; self.date = date; self.kind = kind
    }
}

/// Turns samples into alerts. A condition must hold for its whole sustain time before
/// it fires (no blips), and each one fires at most once per cooldown.
public final class AlertMonitor {
    public static let cooldown: TimeInterval = 1800
    private var since: [String: Date] = [:]
    private var lastFired: [String: Date] = [:]
    private var swap: [(Date, UInt64)] = []

    public init() {}

    /// `processes` is nil on ticks without a process sample; per-process conditions then
    /// keep their state instead of resetting. `appWatts`: current watts per app.
    public func evaluate(_ s: Snapshot, processes: [ProcessStat]?, appWatts: [String: Double],
                         settings: AlertSettings, now: Date = Date()) -> [FanAlert] {
        var out: [FanAlert] = []
        func check(_ key: String, _ active: Bool, sustain: TimeInterval, _ title: @autoclosure () -> String, _ body: @autoclosure () -> String) {
            guard active else { since[key] = nil; return }
            let start = since[key] ?? now
            since[key] = start
            guard now.timeIntervalSince(start) >= sustain,
                  now.timeIntervalSince(lastFired[key] ?? .distantPast) >= Self.cooldown else { return }
            lastFired[key] = now
            let alert = FanAlert(key: key, title: title(), body: body(), date: now)
            Log.app.warning("Alert: \(alert.title) - \(alert.body)")
            out.append(alert)
        }

        if let disk = s.volumes.first(where: { $0.name == "Macintosh HD" }) {
            let free = Double(disk.available) / 1e9
            check("disk", settings.lowDisk && free < settings.lowDiskGB, sustain: 0,
                  "Disk almost full", String(format: "%.1f GB free. The Storage tab shows what is safe to clear.", free))
        }
        if let m = s.memory {
            check("pressure", settings.memoryPressure && m.pressure >= settings.pressure, sustain: 120,
                  "Memory pressure high", "\(Format.percent(m.pressure)) for 2 minutes; the Memory tab shows who is using it.")
            swap.append((now, m.swapUsed))
            swap.removeAll { now.timeIntervalSince($0.0) > 600 }
            let grew = Double(Int64(bitPattern: m.swapUsed &- (swap.first?.1 ?? m.swapUsed))) / 1e9
            check("swap", settings.swapGrowth && grew >= settings.swapGBPer10Min, sustain: 0,
                  "Swap growing fast", String(format: "+%.1f GB in 10 minutes (%@ in use)", grew, Format.memory(m.swapUsed)))
        }
        if let soc = s.socMax {
            check("chip", settings.hotChip && soc >= settings.chipCelsius, sustain: 60,
                  "Chip running hot", String(format: "%.0f °C for a minute; fans at %@ rpm", soc, Format.rpm(s.fans.map(\.actual).max() ?? 0)))
        }
        if let t = s.batteryTemp {
            check("battery-heat", settings.hotBattery && t >= settings.batteryCelsius, sustain: 60,
                  "Battery hot", String(format: "%.0f °C. Heat ages a battery fastest, above all while charging.", t))
        }
        if let processes {
            let leakBytes = settings.leakMBPerMinute * 1e6
            var leaking = Set<String>()
            for p in processes where settings.leaks && p.readable && Double(p.growth) >= leakBytes {
                let key = "leak:\(p.pid):\(p.start)"
                leaking.insert(key)
                check(key, true, sustain: 300, "\(p.name) keeps growing",
                      "+\(Format.bytes(Double(p.growth))) in the last minute, now \(Format.bytes(Double(p.memory))). Possible leak.")
            }
            for key in since.keys where key.hasPrefix("leak:") && !leaking.contains(key) { since[key] = nil }
        }
        let onBattery = s.power.map { !$0.onAC } ?? false
        var draining = Set<String>()
        for (app, watts) in appWatts where settings.batteryDrain && onBattery && watts >= settings.appWatts {
            let key = "drain:\(app)"
            draining.insert(key)
            check(key, true, sustain: 300, "\(app) is draining the battery",
                  String(format: "%.1f W for 5 minutes. The Energy tab shows what quitting it would gain.", watts))
        }
        if !appWatts.isEmpty { for key in since.keys where key.hasPrefix("drain:") && !draining.contains(key) { since[key] = nil } }
        return out
    }
}
