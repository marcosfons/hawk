import Foundation

/// A device's system, in full (requirements 2.3): read once per connection.
public struct SystemInfo: Sendable, Equatable, Codable {
    /// Every property `getprop` printed.
    public var props: [String: String] = [:]
    public var kernel: String?
    public var selinux: String?
    public var ramKB: Int?
    /// Swap, including zram ("RAM Plus" and the like are swap).
    public var swapKB: Int?
    public var displaySize: String?
    public var density: String?
    public var suPresent = false

    public init() {}

    public var model: String? { props["ro.product.model"] }
    public var manufacturer: String? { props["ro.product.manufacturer"] }
    public var soc: String? { props["ro.soc.model"] ?? props["ro.board.platform"] }
    public var android: String? { props["ro.build.version.release"] }
    public var sdk: String? { props["ro.build.version.sdk"] }
    public var build: String? { props["ro.build.display.id"] ?? props["ro.build.id"] }
    public var securityPatch: String? { props["ro.build.version.security_patch"] }
    public var abis: String? { props["ro.product.cpu.abilist"] }
    public var verifiedBoot: String? { props["ro.boot.verifiedbootstate"] }
    public var encryption: String? {
        guard let state = props["ro.crypto.state"] else { return nil }
        return [state, props["ro.crypto.type"].map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
    }
    /// nil when the device does not say.
    public var bootloaderLocked: Bool? {
        switch props["ro.boot.flash.locked"] ?? props["ro.boot.vbmeta.device_state"] {
        case "1", "locked": true
        case "0", "unlocked": false
        default: nil
        }
    }
    /// Signs of root: `su` on the path, an unlocked bootloader, a debuggable build.
    public var rootIndicators: [String] {
        var out: [String] = []
        if suPresent { out.append("su present") }
        if bootloaderLocked == false { out.append("bootloader unlocked") }
        if props["ro.debuggable"] == "1" { out.append("debuggable build") }
        if verifiedBoot == "orange" { out.append("verified boot orange") }
        return out
    }
}

/// What the device is doing right now (requirements 2.1).
public struct RightNow: Sendable, Equatable, Codable {
    public var foreground: String?
    public var battery: BatteryInfo?
    public var screenOn: Bool?
    public var locked: Bool?
    public var doNotDisturb: String?
    public init() {}
}

public struct BatteryInfo: Sendable, Equatable, Codable {
    public var level: Int?
    public var status: String?
    /// "AC", "USB", "Wireless", "Dock", or nil when on battery.
    public var source: String?
    public var temperature: Double?
    public var health: String?
    /// As the device reports it, where it does (mA on some, µA on others).
    public var current: Int?
    public init() {}
}

/// The shell reads behind the Overview, and their parsers. Phone-side cost is the
/// budget (adbd + shell under 2% of a core): one batch per 3 s tick, and only what
/// changes fast is read every tick.
public enum OverviewProbe {
    /// Once per connection.
    public static let system: [String: String] = [
        "props": "getprop",
        "kernel": "uname -r",
        "selinux": "getenforce",
        "mem": "grep -E '^(MemTotal|SwapTotal):' /proc/meminfo",
        "size": "wm size",
        "density": "wm density",
        "su": "command -v su >/dev/null 2>&1 && echo yes || echo no",
    ]

    /// Measured on a phone (client side, per run): focused window 20 ms, battery
    /// 20 ms, power 24 ms, keyguard 30 ms, `settings` 40 ms (it starts app_process).
    /// So: the foreground app every tick, battery every other tick, screen, lock and
    /// Do Not Disturb every tenth (and on the first).
    public static func rightNow(tick: Int) -> [String: String] {
        var parts = ["focus": "dumpsys window displays | grep -m1 mCurrentFocus"]
        if tick % 2 == 0 { parts["battery"] = "dumpsys battery" }
        if tick % 10 == 0 {
            parts["power"] = "dumpsys power | grep -m1 mWakefulness="
            parts["keyguard"] = "dumpsys window policy | grep -A2 KeyguardServiceDelegate"
            parts["zen"] = "settings get global zen_mode"
        }
        return parts
    }

    public static func parseSystem(_ parts: [String: String]) -> SystemInfo {
        var s = SystemInfo()
        s.props = parseGetprop(parts["props"] ?? "")
        s.kernel = firstLine(parts["kernel"])
        s.selinux = firstLine(parts["selinux"])
        let mem = keyValues(parts["mem"] ?? "", separator: ":")
        s.ramKB = mem["MemTotal"].flatMap(leadingInt)
        s.swapKB = mem["SwapTotal"].flatMap(leadingInt)
        s.displaySize = value(after: ":", in: parts["size"], preferring: "Override size") ?? value(after: ":", in: parts["size"], preferring: "Physical size")
        s.density = value(after: ":", in: parts["density"], preferring: "Override density") ?? value(after: ":", in: parts["density"], preferring: "Physical density")
        s.suPresent = firstLine(parts["su"]) == "yes"
        return s
    }

    /// Updates `now` with whatever parts this tick read; the rest keeps its last value.
    public static func merge(_ parts: [String: String], into now: RightNow) -> RightNow {
        var r = now
        if let focus = parts["focus"] { r.foreground = parseFocus(focus) }
        if let battery = parts["battery"] { r.battery = parseBattery(battery) }
        if let power = parts["power"] { r.screenOn = parseWakefulness(power) }
        if let keyguard = parts["keyguard"] { r.locked = parseKeyguard(keyguard) }
        if let zen = parts["zen"] { r.doNotDisturb = parseZen(zen) }
        return r
    }

    /// `[ro.product.model]: [Fake Phone]` lines; capped in count and length.
    public static func parseGetprop(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.prefix(512 * 1024).split(whereSeparator: \.isNewline).prefix(5000) {
            guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { continue }
            let key = line[line.index(after: line.startIndex)..<close]
            let rest = line[line.index(after: close)...]
            guard let open = rest.firstIndex(of: "["), let end = rest.lastIndex(of: "]"), open < end, !key.isEmpty, key.count <= 256 else { continue }
            out[String(key)] = String(rest[rest.index(after: open)..<end].prefix(1024))
        }
        return out
    }

    /// "mCurrentFocus=Window{8b3887b u0 com.example.app/com.example.app.MainActivity}"
    /// -> "com.example.app/com.example.app.MainActivity"; system windows by their name.
    public static func parseFocus(_ text: String) -> String? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.contains("mCurrentFocus=") }),
              let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close else { return nil }
        let words = line[line.index(after: open)..<close].split(separator: " ")
        guard words.count >= 3 else { return nil }
        return String(words[2...].joined(separator: " ").prefix(256))
    }

    public static func parseBattery(_ text: String) -> BatteryInfo {
        let kv = keyValues(text, separator: ":")
        var b = BatteryInfo()
        b.level = kv["level"].flatMap(leadingInt)
        if let scale = kv["scale"].flatMap(leadingInt), scale > 0, scale != 100, let level = b.level { b.level = level * 100 / scale }
        b.status = kv["status"].flatMap(leadingInt).map {
            switch $0 { case 2: "Charging"; case 3: "Discharging"; case 4: "Not charging"; case 5: "Full"; default: "Unknown" }
        }
        b.source = [("AC powered", "AC"), ("USB powered", "USB"), ("Wireless powered", "Wireless"), ("Dock powered", "Dock")]
            .first { kv[$0.0] == "true" }?.1
        b.temperature = kv["temperature"].flatMap(leadingInt).map { Double($0) / 10 }
        b.health = kv["health"].flatMap(leadingInt).map {
            switch $0 { case 2: "Good"; case 3: "Overheat"; case 4: "Dead"; case 5: "Over voltage"; case 6: "Failure"; case 7: "Cold"; default: "Unknown" }
        }
        b.current = kv["current now"].flatMap(leadingInt)
        return b
    }

    /// "mWakefulness=Awake" (Asleep, Dozing, Dreaming): only Awake has the screen on.
    public static func parseWakefulness(_ text: String) -> Bool? {
        guard let range = text.range(of: "mWakefulness=") else { return nil }
        let word = text[range.upperBound...].prefix { $0.isLetter }
        return word.isEmpty ? nil : word == "Awake"
    }

    /// `showing=true` under KeyguardServiceDelegate.
    public static func parseKeyguard(_ text: String) -> Bool? {
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("showing=") { return t.dropFirst(8).hasPrefix("true") }
        }
        return nil
    }

    /// `settings get global zen_mode`: 0 off, 1 priority only, 2 total silence, 3 alarms only.
    public static func parseZen(_ text: String) -> String? {
        switch firstLine(text).flatMap({ Int($0) }) {
        case 0: "Off"
        case 1: "Priority only"
        case 2: "Total silence"
        case 3: "Alarms only"
        default: nil
        }
    }

    // MARK: -

    static func firstLine(_ text: String?) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first else { return nil }
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(256))
    }

    static func keyValues(_ text: String, separator: Character) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.prefix(256 * 1024).split(whereSeparator: \.isNewline).prefix(2000) {
            guard let i = line.firstIndex(of: separator) else { continue }
            let key = line[..<i].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.count <= 64, out[key] == nil else { continue }
            out[key] = String(line[line.index(after: i)...].trimmingCharacters(in: .whitespaces).prefix(256))
        }
        return out
    }

    static func leadingInt(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let digits = t.prefix { $0.isNumber || $0 == "-" }
        return digits.count <= 12 ? Int(digits) : nil
    }

    /// "Physical size: 1080x2400" -> "1080x2400", from the line starting with `label`.
    static func value(after separator: Character, in text: String?, preferring label: String) -> String? {
        guard let line = text?.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix(label) }),
              let i = line.firstIndex(of: separator) else { return nil }
        let v = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : String(v.prefix(64))
    }
}
