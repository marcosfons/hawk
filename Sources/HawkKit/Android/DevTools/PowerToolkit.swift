import Foundation

/// Why an app may stop working in the background (requirements 14.1): its battery
/// exemption, standby bucket, app ops, location permission, and what it holds now.
public struct AppPowerState: Sendable, Equatable {
    /// "user", "system", "system-excidle", or nil when not exempt from battery optimisation.
    public var exemption: String?
    public var bucket: Int?
    public var appOps: [String: String] = [:]
    public var fineLocation: Bool?
    public var coarseLocation: Bool?
    public var backgroundLocation: Bool?
    public var locationRequests = 0
    public var wakelocks = 0
    public var alarms = 0
    public var foregroundServices = 0

    public init() {}

    public var bucketName: String? {
        bucket.map {
            switch $0 {
            case 5: "Exempted"
            case 10: "Active"
            case 20: "Working set"
            case 30: "Frequent"
            case 40: "Rare"
            case 45: "Restricted"
            case 50: "Never"
            default: "Bucket \($0)"
            }
        }
    }

    /// App ops that decide background work and location.
    public static let interestingOps = ["RUN_IN_BACKGROUND", "RUN_ANY_IN_BACKGROUND", "COARSE_LOCATION", "FINE_LOCATION",
                                        "MONITOR_LOCATION", "MONITOR_HIGH_POWER_LOCATION", "WAKE_LOCK", "SCHEDULE_EXACT_ALARM"]

    /// One batch for one package; nil when the name is not a package.
    public static func parts(_ package: String) -> [String: String]? {
        guard let p = ShellQuote.package(package) else { return nil }
        return [
            "idle": "dumpsys deviceidle whitelist",
            "bucket": "am get-standby-bucket \(p)",
            "ops": "cmd appops get \(p)",
            "perms": "dumpsys package \(p) | grep -E 'ACCESS_(FINE|COARSE|BACKGROUND)_LOCATION'",
            "location": "dumpsys location | grep -c \(p)",
            "power": "dumpsys power | grep -i wake_lock | grep -c \(p)",
            "alarm": "dumpsys alarm | grep -c \(p)",
            "services": "dumpsys activity services \(p) | grep -c 'isForeground=true'",
        ]
    }

    public static func parse(_ parts: [String: String], package: String) -> AppPowerState {
        var s = AppPowerState()
        for line in (parts["idle"] ?? "").prefix(256 * 1024).split(whereSeparator: \.isNewline) {
            let f = line.split(separator: ",")
            if f.count >= 2, f[1] == package { s.exemption = String(f[0]).trimmingCharacters(in: .whitespaces); break }
        }
        s.bucket = Int((parts["bucket"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        for line in (parts["ops"] ?? "").prefix(256 * 1024).split(whereSeparator: \.isNewline) {
            // "Uid mode: COARSE_LOCATION: ignore" or "RUN_IN_BACKGROUND: allow; time=..."
            let t = line.hasPrefix("Uid mode: ") ? line.dropFirst(10) : line
            guard let colon = t.firstIndex(of: ":") else { continue }
            let op = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
            guard interestingOps.contains(op), s.appOps[op] == nil else { continue }
            s.appOps[op] = String(t[t.index(after: colon)...].split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces)
        }
        for line in (parts["perms"] ?? "").split(whereSeparator: \.isNewline) {
            let granted = line.contains("granted=true")
            if line.contains("ACCESS_FINE_LOCATION") { s.fineLocation = (s.fineLocation ?? false) || granted }
            if line.contains("ACCESS_COARSE_LOCATION") { s.coarseLocation = (s.coarseLocation ?? false) || granted }
            if line.contains("ACCESS_BACKGROUND_LOCATION") { s.backgroundLocation = (s.backgroundLocation ?? false) || granted }
        }
        func count(_ key: String) -> Int { Int((parts[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        s.locationRequests = count("location")
        s.wakelocks = count("power")
        s.alarms = count("alarm")
        s.foregroundServices = count("services")
        return s
    }
}

/// A state forced on a device to test without waiting hours, with its undo.
public enum PowerForce: Sendable, Hashable, Codable {
    case doze
    case standbyBucket(package: String, to: Int, from: Int)
    case inactive(package: String)
    case unplugBattery

    public var title: String {
        switch self {
        case .doze: "Doze forced"
        case .standbyBucket(let p, let to, _): "\(p) in standby bucket \(to)"
        case .inactive(let p): "\(p) inactive"
        case .unplugBattery: "Battery unplugged (simulated)"
        }
    }

    /// nil when a package name is not valid.
    public var command: String? {
        switch self {
        case .doze: "dumpsys deviceidle force-idle"
        case .standbyBucket(let p, let to, _): ShellQuote.package(p).map { "am set-standby-bucket \($0) \(to)" }
        case .inactive(let p): ShellQuote.package(p).map { "am set-inactive \($0) true" }
        case .unplugBattery: "dumpsys battery unplug"
        }
    }

    public var undo: String? {
        switch self {
        case .doze: "dumpsys deviceidle unforce"
        case .standbyBucket(let p, _, let from): ShellQuote.package(p).map { "am set-standby-bucket \($0) \(from)" }
        case .inactive(let p): ShellQuote.package(p).map { "am set-inactive \($0) false" }
        case .unplugBattery: "dumpsys battery reset"
        }
    }
}

/// What is forced on a device, kept in its folder so it is undone when the device
/// comes back after a disconnect (the phone keeps some of these until reboot).
public enum PowerForces {
    public static let file = "forced.json"

    public static func load(_ id: DeviceID, store: DeviceStore?) async -> [PowerForce] {
        await store?.load([PowerForce].self, file, for: id) ?? []
    }

    public static func save(_ forces: [PowerForce], _ id: DeviceID, store: DeviceStore?) async {
        await store?.save(forces, as: file, for: id)
        await store?.flush()
    }

    /// Runs `force` and remembers it; logged.
    public static func apply(_ force: PowerForce, on session: any DeviceSession, deviceName: String, store: DeviceStore?) async -> Bool {
        guard let command = force.command else { return false }
        let ok = (try? await session.shell(command, timeout: .seconds(15))).map { $0.status == 0 } ?? false
        if ok { await save(await load(session.id, store: store) + [force], session.id, store: store) }
        await log(force.title, ok, session: session, deviceName: deviceName, store: store)
        return ok
    }

    /// Undoes every forced state still remembered (the Undo all button, and on reconnect).
    public static func undoAll(on session: any DeviceSession, deviceName: String, store: DeviceStore?) async {
        let forces = await load(session.id, store: store)
        guard !forces.isEmpty else { return }
        var left: [PowerForce] = []
        for f in forces.reversed() {
            guard let undo = f.undo else { continue }
            let ok = (try? await session.shell(undo, timeout: .seconds(15))).map { $0.status == 0 } ?? false
            if !ok { left.insert(f, at: 0) }
            await log("Undo: \(f.title)", ok, session: session, deviceName: deviceName, store: store)
        }
        await save(left, session.id, store: store)
    }

    public static func undo(_ force: PowerForce, on session: any DeviceSession, deviceName: String, store: DeviceStore?) async {
        guard let undo = force.undo else { return }
        let ok = (try? await session.shell(undo, timeout: .seconds(15))).map { $0.status == 0 } ?? false
        if ok { await save(await load(session.id, store: store).filter { $0 != force }, session.id, store: store) }
        await log("Undo: \(force.title)", ok, session: session, deviceName: deviceName, store: store)
    }

    private static func log(_ what: String, _ ok: Bool, session: any DeviceSession, deviceName: String, store: DeviceStore?) async {
        guard let store else { return }
        try? await ActionLog.append(device: deviceName, action: .change(what), result: ok ? .done : .failed("command failed"), id: session.id, store: store)
    }
}
