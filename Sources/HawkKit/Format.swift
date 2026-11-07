import Foundation

/// Human-readable numbers, shared by the app and the command line.
public enum Format {
    /// Decimal units, like Finder and Activity Monitor's disk and network columns.
    public static func bytes(_ b: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = max(b, 0), i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        if i == 0 { return String(format: "%.0f B", v) }
        return String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    public static func rate(_ bytesPerSecond: Double) -> String { bytes(bytesPerSecond) + "/s" }

    /// Memory in binary gigabytes, labelled GB as macOS does (24 GB of RAM = 24 × 2^30 bytes).
    public static func memory(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }

    public static func percent(_ fraction: Double) -> String { String(format: "%.0f%%", fraction * 100) }

    public static func celsius(_ c: Double?) -> String { c.map { String(format: "%.0f°", $0) } ?? "-" }

    public static func rpm(_ r: Double) -> String { String(format: "%.0f", r) }

    public static func watts(_ w: Double?) -> String { w.map { String(format: abs($0) < 10 ? "%.1f W" : "%.0f W", $0) } ?? "-" }

    /// Accumulated CPU time, like Activity Monitor: 1:02:03 or 4:05.67.
    public static func cpuTime(_ seconds: Double) -> String {
        let s = max(seconds, 0)
        if s >= 3600 { return String(format: "%d:%02d:%02d", Int(s) / 3600, Int(s) / 60 % 60, Int(s) % 60) }
        return String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    /// A change in size, with its sign: "+12 MB", "-3.4 MB", "0".
    public static func signedBytes(_ b: Int64) -> String {
        b == 0 ? "0" : (b > 0 ? "+" : "-") + bytes(Double(b.magnitude))
    }

    /// Small per-process power: two decimals below 1 W.
    public static func processWatts(_ w: Double) -> String { String(format: w < 1 ? "%.2f" : "%.1f", w) }

    /// "now", "5 min ago", "3 h ago", "2 d ago", "4 mo ago", "2 y ago".
    public static func ago(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "-" }
        let s = max(now.timeIntervalSince(date), 0)
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(Int(s / 60)) min ago"
        case ..<86400: return "\(Int(s / 3600)) h ago"
        case ..<(86400 * 60): return "\(Int(s / 86400)) d ago"
        case ..<(86400 * 730): return "\(Int(s / (86400 * 30))) mo ago"
        default: return "\(Int(s / (86400 * 365))) y ago"
        }
    }

    public static func minutes(_ m: Int?) -> String { m.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "-" }
}
