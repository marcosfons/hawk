import Foundation

/// Hotspot state from `dumpsys tethering` (requirements 7.1): an interface listed as
/// TETHERED under "Tether state" means the phone is sharing its connection.
public enum Tethering {
    public static let command = "dumpsys tethering 2>/dev/null | sed -n '/Tether state:/,/Upstream/p' | grep -E ' - [A-Z]+' | head -n 20"

    public static func tetheredInterfaces(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.contains(" - TETHERED") else { return nil }
            return line.split(separator: " ").first.map { String($0.prefix(32)) }
        }
    }
}

/// Data used by the whole device, from the per-day history plan B keeps (no phone
/// call): totals for a number of days, Wi-Fi, mobile and hotspot.
public enum DeviceDataTotals {
    public static func totals(_ history: UsageHistory, days: Int, now: Date = Date()) -> (wifi: Int64, mobile: Int64, hotspot: Int64) {
        let t = history.totals(lastDays: days, now: now)
        let wifi = t.values.reduce(0) { $0 + $1.wifi }
        let mobile = t.values.reduce(0) { $0 + $1.mobile }
        let hotspot = (t[-5]?.wifi ?? 0) + (t[-5]?.mobile ?? 0)
        return (wifi, mobile, hotspot)
    }
}

/// Wi-Fi networks saved on the phone, from `cmd wifi list-networks` (requirements 7.2).
public struct SavedWifi: Sendable, Equatable, Identifiable {
    public let id: Int
    public let ssid: String
    public let security: String

    public init(id: Int, ssid: String, security: String) {
        self.id = id
        self.ssid = ssid
        self.security = security
    }

    public static let command = "cmd wifi list-networks 2>&1"

    /// "0            Home Network                 wpa2-psk": the SSID may hold spaces.
    public static func parse(_ text: String) -> [SavedWifi] {
        text.split(whereSeparator: \.isNewline).dropFirst().prefix(500).compactMap { line in
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let id = Int(f[0]) else { return nil }
            let ssid = f[1..<(f.count - 1)].joined(separator: " ")
            return SavedWifi(id: id, ssid: String(ssid.prefix(64)), security: String(f[f.count - 1].prefix(24)))
        }
    }

    /// Adds a network on the phone. The passphrase is only in this one command:
    /// never logged (the runner logs "adb shell" only), stored or shown.
    public static func addCommand(ssid: String, security: String, passphrase: String?) -> String? {
        guard !ssid.isEmpty, ssid.count <= 32, !ssid.contains(where: \.isNewline),
              ["open", "owe", "wpa2", "wpa3", "wep"].contains(security) else { return nil }
        if security != "open", security != "owe" {
            guard let p = passphrase, (8...63).contains(p.count), !p.contains(where: \.isNewline) else { return nil }
            return "cmd wifi add-network \(ShellQuote.quote(ssid)) \(security) \(ShellQuote.quote(p))"
        }
        return "cmd wifi add-network \(ShellQuote.quote(ssid)) \(security)"
    }
}

/// The Mac's side of Wi-Fi sharing: its saved networks, and a password from the
/// keychain (macOS asks the user first).
public enum MacWifi {
    /// "Hardware Port: Wi-Fi\nDevice: en0" -> "en0".
    public static func interface(fromHardwarePorts text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline)
        for (i, line) in lines.enumerated() where line.hasSuffix("Wi-Fi") || line.hasSuffix("AirPort") {
            if i + 1 < lines.count, lines[i + 1].hasPrefix("Device: ") { return String(lines[i + 1].dropFirst(8)) }
        }
        return nil
    }

    /// `networksetup -listpreferredwirelessnetworks en0`: a header, then tab-indented SSIDs.
    public static func preferred(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(200).map { String($0) }
    }

    public static func savedNetworks() async -> [String] {
        let ns = AdbProcess(executable: "/usr/sbin/networksetup")
        guard let ports = try? await ns.run(["-listallhardwareports"], timeout: .seconds(5)),
              let iface = interface(fromHardwarePorts: ports.text),
              let list = try? await ns.run(["-listpreferredwirelessnetworks", iface], timeout: .seconds(5)) else { return [] }
        return preferred(list.text)
    }

    /// The password macOS saved for a network; macOS shows its own prompt first.
    public static func password(for ssid: String) async -> String? {
        let security = AdbProcess(executable: "/usr/bin/security")
        guard let out = try? await security.run(["find-generic-password", "-D", "AirPort network password", "-a", ssid, "-w"], timeout: .seconds(120)),
              out.status == 0 else { return nil }
        let p = out.text.trimmingCharacters(in: .newlines)
        return p.isEmpty ? nil : p
    }
}

/// The phone's trusted system CAs (requirements 7.6): subjects from the certificate
/// files' own text. User-added CAs are readable only with root.
public enum CAStore {
    public static let command = "grep -h -m1 'Subject:' /apex/com.android.conscrypt/cacerts/* 2>/dev/null || grep -h -m1 'Subject:' /system/etc/security/cacerts/* 2>/dev/null"

    /// "Subject: C=US, O=Example, CN=Example Root" -> "Example Root (Example)".
    public static func parse(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).prefix(1000).compactMap { line in
            guard let r = line.range(of: "Subject: ") else { return nil }
            let fields = line[r.upperBound...].components(separatedBy: ", ")
            func value(_ key: String) -> String? { fields.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } }
            let cn = value("CN") ?? value("OU") ?? value("O")
            guard let cn else { return nil }
            let o = value("O")
            return String((o != nil && o != cn ? "\(cn) (\(o!))" : cn).prefix(120))
        }.sorted()
    }
}
