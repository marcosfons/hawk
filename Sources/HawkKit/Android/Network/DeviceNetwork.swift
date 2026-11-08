import Foundation

/// A device's network configuration (requirements 7.3), read once when the page
/// opens: Private DNS, proxy, interfaces with their addresses, routes, VPN.
public struct NetworkConfig: Sendable, Equatable {
    public struct Interface: Sendable, Equatable {
        public let name: String
        public var addresses: [String]
    }

    public var privateDNS: String?
    public var proxy: String?
    public var interfaces: [Interface] = []
    public var routes: [String] = []
    public var vpn: Bool { interfaces.contains { $0.name.hasPrefix("tun") || $0.name.hasPrefix("ppp") || $0.name.hasPrefix("ipsec") } }

    public init() {}

    public static let parts: [String: String] = [
        "dnsMode": "settings get global private_dns_mode",
        "dnsHost": "settings get global private_dns_specifier",
        "proxy": "settings get global http_proxy",
        "addr": "ip -o addr show 2>/dev/null",
        "route": "ip route 2>/dev/null; ip -6 route 2>/dev/null | grep -v '^fe80'",
    ]

    public static func parse(_ p: [String: String]) -> NetworkConfig {
        var c = NetworkConfig()
        let mode = value(p["dnsMode"])
        switch mode {
        case "off": c.privateDNS = "Off"
        case "opportunistic", nil: c.privateDNS = "Automatic"
        case "hostname": c.privateDNS = value(p["dnsHost"]).map { "Provider: \($0)" } ?? "Provider"
        case let other?: c.privateDNS = other
        }
        // ":0" (or empty, or null) means no proxy.
        if let proxy = value(p["proxy"]), proxy != ":0" { c.proxy = proxy }
        var order: [String] = []
        var byName: [String: [String]] = [:]
        for line in (p["addr"] ?? "").prefix(256 * 1024).split(whereSeparator: \.isNewline).prefix(500) {
            // "3: wlan0    inet 192.0.2.10/24 brd ... scope global wlan0"
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, let i = f.firstIndex(where: { $0 == "inet" || $0 == "inet6" }), i + 1 < f.count else { continue }
            let name = String(f[1]).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard name != "lo", !f[i + 1].hasPrefix("fe80") else { continue }
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(String(f[i + 1].prefix(64)))
        }
        c.interfaces = order.map { Interface(name: String($0.prefix(32)), addresses: byName[$0] ?? []) }
        c.routes = (p["route"] ?? "").split(whereSeparator: \.isNewline).prefix(100).map { String($0.prefix(200)) }
        return c
    }

    static func value(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != "null" else { return nil }
        return String(t.prefix(200))
    }
}

/// One TCP socket from /proc/net/tcp or tcp6 (requirements 7.4, open connections).
public struct Connection: Sendable, Equatable, Identifiable {
    public let local: String
    public let localPort: Int
    public let remote: String
    public let remotePort: Int
    public let state: String
    public let uid: Int
    public var id: String { "\(local):\(localPort)-\(remote):\(remotePort)-\(uid)" }

    public static let command = "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"

    static let states = ["01": "Established", "02": "Syn sent", "03": "Syn received", "04": "Fin wait 1", "05": "Fin wait 2",
                         "06": "Time wait", "07": "Closed", "08": "Close wait", "09": "Last ack", "0A": "Listen", "0B": "Closing"]

    public static func parse(_ text: String) -> [Connection] {
        var out: [Connection] = []
        for line in text.prefix(2 << 20).split(whereSeparator: \.isNewline).prefix(20_000) {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 8, f[0].hasSuffix(":"), let (la, lp) = endpoint(f[1]), let (ra, rp) = endpoint(f[2]),
                  let uid = Int(f[7]) else { continue }
            out.append(Connection(local: la, localPort: lp, remote: ra, remotePort: rp, state: states[String(f[3])] ?? String(f[3].prefix(4)), uid: uid))
        }
        return out
    }

    /// "0200A8C0:BFE0" (IPv4, little-endian) or 32 hex digits of IPv6 in four
    /// little-endian words; IPv4-mapped IPv6 shown as IPv4.
    static func endpoint(_ s: Substring) -> (String, Int)? {
        let parts = s.split(separator: ":")
        guard parts.count == 2, let port = Int(parts[1], radix: 16) else { return nil }
        let hex = parts[0]
        func bytes(_ h: Substring) -> [UInt8]? {
            guard h.count % 2 == 0 else { return nil }
            var out: [UInt8] = []
            var i = h.startIndex
            while i < h.endIndex {
                let j = h.index(i, offsetBy: 2)
                guard let b = UInt8(h[i..<j], radix: 16) else { return nil }
                out.append(b)
                i = j
            }
            return out
        }
        guard let raw = bytes(hex) else { return nil }
        if raw.count == 4 { return (raw.reversed().map(String.init).joined(separator: "."), port) }
        guard raw.count == 16 else { return nil }
        // Each 4-byte word is little-endian.
        let ordered = stride(from: 0, to: 16, by: 4).flatMap { raw[$0..<$0 + 4].reversed() }
        if ordered[0..<10].allSatisfy({ $0 == 0 }), ordered[10] == 0xFF, ordered[11] == 0xFF {
            return (ordered[12...].map(String.init).joined(separator: "."), port)
        }
        if ordered.allSatisfy({ $0 == 0 }) { return ("::", port) }
        let groups = stride(from: 0, to: 16, by: 2).map { String(format: "%x", Int(ordered[$0]) << 8 | Int(ordered[$0 + 1])) }
        return (groups.joined(separator: ":"), port)
    }
}

/// An adb tunnel (requirements 7.5): forward (Mac port to device) or reverse
/// (device port to Mac).
public struct Tunnel: Sendable, Hashable, Codable, Identifiable {
    public enum Direction: String, Sendable, Codable { case forward, reverse }
    public let direction: Direction
    public let local: String
    public let remote: String
    public var id: String { "\(direction.rawValue) \(local) \(remote)" }

    public init(direction: Direction, local: String, remote: String) {
        self.direction = direction
        self.local = local
        self.remote = remote
    }

    /// "tcp:8080", "localabstract:chrome_devtools_remote": only the forms adb takes.
    public static func isSpec(_ s: String) -> Bool {
        s.wholeMatch(of: /(tcp:\d{1,5}|localabstract:[A-Za-z0-9_.\-]{1,100}|localfilesystem:\/[A-Za-z0-9_.\/\-]{1,200}|jdwp:\d{1,7})/) != nil
    }

    /// Arguments for `adb -s <serial> ...`; nil when a side is not a valid spec.
    public var addArguments: [String]? {
        guard Self.isSpec(local), Self.isSpec(remote) else { return nil }
        return [direction.rawValue, local, remote]
    }

    public var removeArguments: [String] { [direction.rawValue, "--remove", local] }

    /// `adb forward --list` ("SERIAL tcp:8080 tcp:8080", every device) or
    /// `adb -s S reverse --list` ("UsbFfs tcp:8081 tcp:8081"): this device's only.
    public static func parse(_ text: String, direction: Direction, serial: String?) -> [Tunnel] {
        text.split(whereSeparator: \.isNewline).prefix(200).compactMap { line in
            let f = line.split(separator: " ")
            guard f.count >= 3 else { return nil }
            if direction == .forward, let serial, f[0] != serial { return nil }
            let t = Tunnel(direction: direction, local: String(f[1]), remote: String(f[2]))
            return isSpec(t.local) && isSpec(t.remote) ? t : nil
        }
    }
}
