import Foundation

/// Energy per app, from the kernel's per-process energy counters (ri_energy_nj).
/// Helper processes count toward their app (every Chrome renderer is "Google Chrome").
/// Counters are cumulative, so sampling every few seconds or every 15 s gives the
/// same totals; only processes that start and exit between two samples are missed.
public struct EnergyUse: Sendable, Identifiable {
    public let id: String           // app name
    public let path: String?        // an executable inside the app, for its icon
    public let joules: Double       // in the chosen window
    public let watts: Double        // right now
    public let processes: Int
    public var wattHours: Double { joules / 3600 }
}

public enum EnergyWindow: String, CaseIterable, Sendable, Identifiable {
    case tenMinutes = "10 min", hour = "1 hour", sinceUnplugged = "Since unplugged"
    public var id: String { rawValue }
}

public final class EnergyTracker {
    struct Key: Hashable, Codable { let pid: Int32; let start: Int }

    struct State: Codable {
        var buckets: [Int: [String: Double]] = [:]      // minute since 1970 -> app -> joules
        var sinceUnplugged: [String: Double] = [:]
        var systemSinceUnplugged = 0.0                   // joules, whole Mac (SMC PSTR)
        var unpluggedAt: Date?
        var systemBuckets: [Int: Double] = [:]
        var savedAt = Date()
    }

    private var state = State()
    private var last: [Key: Double] = [:]               // joules seen at the previous sample
    private var paths: [String: String] = [:]
    private var lastSystem: Date?
    private var lastSave = Date()
    private let stateURL: URL?

    public private(set) var current: [String: (watts: Double, processes: Int)] = [:]
    public var unpluggedAt: Date? { state.unpluggedAt }

    /// `stateURL` keeps totals across restarts (buckets of the last hour, and the
    /// since-unplugged sums while still on battery).
    public init(stateURL: URL?) {
        self.stateURL = stateURL
        if let stateURL, let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
            prune(now: Date())
        }
    }

    /// The app a process belongs to: its outermost .app bundle, else its own name.
    public static func app(_ p: ProcessStat) -> String {
        if let path = p.path, let r = path.range(of: ".app/") {
            return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        }
        return p.name
    }

    /// Feed every process sample. `systemWatts` is the whole Mac's draw right now.
    public func record(_ processes: [ProcessStat], systemWatts: Double?, onAC: Bool, now: Date = Date()) {
        if onAC {
            if state.unpluggedAt != nil { state.unpluggedAt = nil; state.sinceUnplugged = [:]; state.systemSinceUnplugged = 0 }
        } else if state.unpluggedAt == nil {
            state.unpluggedAt = now
        }
        let minute = Int(now.timeIntervalSince1970 / 60)
        var seen: [Key: Double] = [:]
        var watts: [String: (Double, Int)] = [:]
        for p in processes where p.readable {
            let key = Key(pid: p.pid, start: p.start)
            let app = Self.app(p)
            seen[key] = p.energy
            if paths[app] == nil { paths[app] = p.path }
            let w = watts[app] ?? (0, 0)
            watts[app] = (w.0 + p.power, w.1 + 1)
            // First sight of a process: no baseline yet, so its earlier energy is not counted.
            guard let before = last[key], p.energy >= before else { continue }
            let delta = p.energy - before
            state.buckets[minute, default: [:]][app, default: 0] += delta
            if state.unpluggedAt != nil { state.sinceUnplugged[app, default: 0] += delta }
        }
        last = seen
        current = watts.mapValues { (watts: $0.0, processes: $0.1) }

        if let systemWatts, let previous = lastSystem {
            let joules = systemWatts * min(now.timeIntervalSince(previous), 60)
            state.systemBuckets[minute, default: 0] += joules
            if state.unpluggedAt != nil { state.systemSinceUnplugged += joules }
        }
        lastSystem = now
        prune(now: now)
        if now.timeIntervalSince(lastSave) > 300 { save() }
    }

    /// Apps by energy used in `window`, biggest first.
    public func usage(_ window: EnergyWindow, now: Date = Date()) -> [EnergyUse] {
        let totals = joules(window, now: now)
        let apps = Set(totals.keys).union(current.keys)
        return apps.map { app in
            EnergyUse(id: app, path: paths[app], joules: totals[app] ?? 0,
                      watts: current[app]?.watts ?? 0, processes: current[app]?.processes ?? 0)
        }
        .sorted { $0.joules == $1.joules ? $0.watts > $1.watts : $0.joules > $1.joules }
    }

    /// The whole Mac's energy in `window`, in joules.
    public func systemJoules(_ window: EnergyWindow, now: Date = Date()) -> Double {
        switch window {
        case .sinceUnplugged: return state.systemSinceUnplugged
        case .hour, .tenMinutes:
            let from = Int(now.timeIntervalSince1970 / 60) - (window == .hour ? 60 : 10)
            return state.systemBuckets.filter { $0.key > from }.values.reduce(0, +)
        }
    }

    private func joules(_ window: EnergyWindow, now: Date) -> [String: Double] {
        switch window {
        case .sinceUnplugged: return state.sinceUnplugged
        case .hour, .tenMinutes:
            let from = Int(now.timeIntervalSince1970 / 60) - (window == .hour ? 60 : 10)
            var out: [String: Double] = [:]
            for (minute, apps) in state.buckets where minute > from {
                for (app, j) in apps { out[app, default: 0] += j }
            }
            return out
        }
    }

    private func prune(now: Date) {
        let keep = Int(now.timeIntervalSince1970 / 60) - 61
        state.buckets = state.buckets.filter { $0.key > keep }
        state.systemBuckets = state.systemBuckets.filter { $0.key > keep }
    }

    public func save() {
        guard let stateURL else { return }
        lastSave = Date()
        state.savedAt = lastSave
        do {
            try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.engine.warning("Could not save energy totals: \(error.localizedDescription)")
        }
    }
}

/// Battery time estimates from the battery's own charge and the Mac's current draw.
public enum BatteryEstimate {
    /// Watt-hours left in the battery.
    public static func wattHoursLeft(_ p: PowerInfo) -> Double {
        Double(p.maxCapacity) * p.voltage / 1000 * Double(p.percent) / 100
    }

    /// Minutes left at `watts` of draw.
    public static func minutes(_ p: PowerInfo, watts: Double) -> Double? {
        guard watts > 0.5 else { return nil }
        return wattHoursLeft(p) / watts * 60
    }

    /// Minutes gained by removing `appWatts` from a draw of `systemWatts`.
    public static func gain(_ p: PowerInfo, systemWatts: Double, appWatts: Double) -> Double? {
        guard appWatts > 0.05, let now = minutes(p, watts: systemWatts),
              let without = minutes(p, watts: max(systemWatts - appWatts, 1)) else { return nil }
        return without - now
    }
}

/// A short, honest description of what the charger is doing.
public enum ChargeStatus {
    public enum Level: Sendable { case good, info, warn }

    public static func describe(_ p: PowerInfo, batteryTemp: Double?) -> (title: String, detail: String, level: Level) {
        let temp = batteryTemp.map { String(format: "battery %.0f °C", $0) }
        if !p.onAC {
            return ("On battery", [p.minutesRemaining.map { "\(Format.minutes($0)) left" }, temp].compactMap { $0 }.joined(separator: " - "), .info)
        }
        if p.fullyCharged { return ("Charged", temp ?? "", .good) }
        if p.isCharging {
            let rate = String(format: "%.0f W into the battery", max(p.batteryPower, 0))
            if p.slowChargingReason != 0 {
                return ("Charging slowly", [rate, temp, "slowed by macOS (heat or power)"].compactMap { $0 }.joined(separator: " - "), .warn)
            }
            if let t = batteryTemp, t >= 35 {
                return ("Charging warm", [rate, temp, "heat while charging ages the battery fastest"].compactMap { $0 }.joined(separator: " - "), .warn)
            }
            return ("Charging", [rate, temp].compactMap { $0 }.joined(separator: " - "), .good)
        }
        if p.notChargingReason != 0 && p.percent < 100 {
            return ("Holding at \(p.percent)%", ["macOS paused charging (charge limit or Optimized Charging)", temp].compactMap { $0 }.joined(separator: " - "), .good)
        }
        return ("On charger, not charging", temp ?? "", .info)
    }
}
