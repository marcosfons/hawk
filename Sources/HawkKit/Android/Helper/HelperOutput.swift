import Foundation

/// One package's metadata from the helper's `apps` command.
public struct HelperApp: Sendable, Equatable, Codable {
    public let name: String
    public let versionCode: Int64
    public let versionName: String
    public let isSystem: Bool
    public let enabled: Bool
    public let firstInstall: Date?
    public let lastUpdate: Date?
    public let targetSdk: Int?
    /// The installing package ("com.android.vending" for Play); nil when unknown.
    public let installer: String?
}

/// A label and a small PNG icon, from `icons`.
public struct HelperIcon: Sendable, Equatable {
    public let name: String
    public let versionCode: Int64
    public let label: String
    /// nil when the app has no icon of its own.
    public let png: Data?
}

/// Data used by one UID in one window, from `net`.
public struct NetRecord: Sendable, Equatable, Codable {
    public enum Transport: String, Sendable, Codable { case wifi, mobile }
    public let transport: Transport
    public let windowStart: Date
    /// App UID, or a special one: -4 removed apps, -5 tethering.
    public let uid: Int
    public let foreground: Bool
    public let rx: Int64
    public let tx: Int64
}

/// Everything one helper run printed, parsed. Output is untrusted: lines, fields and
/// counts are capped, and a run without its final "D" line is marked incomplete.
public struct HelperOutput: Sendable, Equatable {
    public var apps: [HelperApp] = []
    public var icons: [HelperIcon] = []
    public var net: [NetRecord] = []
    public var errors: [String] = []
    /// cpu_ms, wall_ms, pss_kb, hwm_kb: what the run cost on the phone.
    public var stats: [String: String] = [:]
    public var complete = false

    public static let maxLine = 64 * 1024
    public static let maxRecords = 200_000
    public static let maxPNG = 32 * 1024

    public init() {}

    public static func parse(_ text: String) -> HelperOutput {
        var out = HelperOutput()
        var count = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            count += 1
            guard count <= maxRecords, raw.utf8.count <= maxLine else { continue }
            let f = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch f[0] {
            case "A" where f.count >= 10:
                guard ShellQuote.isPackageName(f[1]) || f[1] == "android", let code = Int64(f[2]) else { continue }
                out.apps.append(HelperApp(name: f[1], versionCode: code, versionName: String(f[3].prefix(64)),
                                          isSystem: f[4] == "1", enabled: f[5] == "1",
                                          firstInstall: date(f[6]), lastUpdate: date(f[7]), targetSdk: Int(f[8]),
                                          installer: f[9].isEmpty ? nil : String(f[9].prefix(128))))
            case "I" where f.count >= 5:
                guard ShellQuote.isPackageName(f[1]) || f[1] == "android", let code = Int64(f[2]) else { continue }
                let png = f[4].isEmpty ? nil : Data(base64Encoded: f[4]).flatMap { $0.count <= maxPNG && isPNG($0) ? $0 : nil }
                out.icons.append(HelperIcon(name: f[1], versionCode: code, label: String(f[3].prefix(128)), png: png))
            case "N" where f.count >= 7:
                guard let transport = f[1] == "w" ? NetRecord.Transport.wifi : f[1] == "m" ? .mobile : nil,
                      let start = date(f[2]), let uid = Int(f[3]), let rx = Int64(f[5]), let tx = Int64(f[6]),
                      rx >= 0, tx >= 0 else { continue }
                out.net.append(NetRecord(transport: transport, windowStart: start, uid: uid, foreground: f[4] == "fg", rx: rx, tx: tx))
            case "E":
                if out.errors.count < 100 { out.errors.append(f.dropFirst().joined(separator: ": ").prefix(300).description) }
            case "S":
                for kv in f.dropFirst() {
                    let parts = kv.split(separator: "=", maxSplits: 1)
                    if parts.count == 2, parts[0].count <= 16 { out.stats[String(parts[0])] = String(parts[1].prefix(32)) }
                }
            case "D":
                out.complete = true
            default:
                continue
            }
        }
        return out
    }

    /// Milliseconds since 1970; nil for zero or nonsense.
    static func date(_ s: String) -> Date? {
        guard let ms = Int64(s), ms > 0, ms < 32_503_680_000_000 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}
