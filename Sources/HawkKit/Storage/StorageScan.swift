import Foundation

/// The output of `mac-scan` (~/personal/storage/mac/scans/latest.json): the storage
/// registry measured. Hawk never walks those locations itself; the scanner already
/// handles hardlinks, mounted images and Docker's VM disk, and keeps per-entry TTLs.
public struct StorageScan: Decodable, Sendable {
    public let scannedAt: Date?
    public let disk: Disk
    public let categories: [String: Category]
    public let totals: Totals
    public let entries: [StorageEntry]

    public struct Disk: Decodable, Sendable {
        public let totalGB, freeGB, usedGB, usedPct: Double
        enum CodingKeys: String, CodingKey { case totalGB = "total_gb", freeGB = "free_gb", usedGB = "used_gb", usedPct = "used_pct" }
    }

    public struct Category: Decodable, Sendable {
        public let label: String
        public let icon: String?
    }

    public struct Totals: Decodable, Sendable {
        public let safeGB, careGB: Double
        enum CodingKeys: String, CodingKey { case safeGB = "reclaimable_safe_gb", careGB = "reclaimable_care_gb" }
    }

    enum CodingKeys: String, CodingKey { case scannedAt = "scanned_at", disk, categories, totals, entries }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scannedAt = (try? c.decode(String.self, forKey: .scannedAt)).flatMap(StorageScan.parseDate)
        disk = try c.decode(Disk.self, forKey: .disk)
        categories = (try? c.decode([String: Category].self, forKey: .categories)) ?? [:]
        totals = try c.decode(Totals.self, forKey: .totals)
        entries = try c.decode([StorageEntry].self, forKey: .entries)
    }

    public static func load(_ url: URL) throws -> StorageScan {
        try JSONDecoder().decode(StorageScan.self, from: Data(contentsOf: url))
    }

    /// mac-scan writes ISO 8601 with microseconds and sometimes no zone.
    public static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            iso.formatOptions = options
            if let d = iso.date(from: s) { return d }
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: String(s.prefix(format.count + 2))) ?? f.date(from: s) { return d }
        }
        return nil
    }
}

public struct StorageEntry: Decodable, Sendable, Identifiable {
    public let id: String
    public let category: String
    public let name: String
    public let kind: String?
    public let risk: Risk
    public let sizeBytes: Int64?
    public let state: String?           // ok | warn | crit | info
    public let warnGB, critGB: Double?
    public let measuredAt: Date?
    public let error: String?
    public let children: [Child]
    public let description, onDelete, regeneratedBy, rebuildCost: String?
    public let care: [String]
    public let reclaim: String?
    public let paths: [String]
    public let overlaps: [String]
    public let countInTotals: Bool
    public let dockerRunning: Bool?

    public enum Risk: String, Decodable, Sendable { case safe, care, never }

    public struct Child: Decodable, Sendable, Identifiable {
        public let path: String
        public let bytes: Int64
        /// Simulator runtimes: simctl's identifier, last use and whether it can be deleted.
        public let identifier: String?
        public let lastUsed: String?
        public let deletable: Bool?
        public let why: String?
        public var id: String { path }
        enum CodingKeys: String, CodingKey { case path, bytes, identifier, lastUsed = "last_used", deletable, why }
    }

    enum CodingKeys: String, CodingKey {
        case id, category, name, kind, risk, sizeBytes = "size_bytes", state, warnGB = "warn_gb", critGB = "crit_gb"
        case measuredAt = "measured_at", error, children, description, onDelete = "on_delete"
        case regeneratedBy = "regenerated_by", rebuildCost = "rebuild_cost", care, reclaim, paths, overlaps
        case countInTotals = "count_in_totals", dockerRunning = "docker_running"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = (try? c.decode(String.self, forKey: .category)) ?? "other"
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        kind = try? c.decode(String.self, forKey: .kind)
        // Anything unrecognised is treated as "never": ambiguous means permanent.
        risk = (try? c.decode(Risk.self, forKey: .risk)) ?? .never
        sizeBytes = try? c.decode(Int64.self, forKey: .sizeBytes)
        state = try? c.decode(String.self, forKey: .state)
        warnGB = try? c.decode(Double.self, forKey: .warnGB)
        critGB = try? c.decode(Double.self, forKey: .critGB)
        measuredAt = (try? c.decode(String.self, forKey: .measuredAt)).flatMap(StorageScan.parseDate)
        error = try? c.decode(String.self, forKey: .error)
        children = (try? c.decode([Child].self, forKey: .children)) ?? []
        description = try? c.decode(String.self, forKey: .description)
        onDelete = try? c.decode(String.self, forKey: .onDelete)
        regeneratedBy = try? c.decode(String.self, forKey: .regeneratedBy)
        rebuildCost = try? c.decode(String.self, forKey: .rebuildCost)
        care = (try? c.decode([String].self, forKey: .care)) ?? []
        reclaim = try? c.decode(String.self, forKey: .reclaim)
        paths = (try? c.decode([String].self, forKey: .paths)) ?? []
        overlaps = (try? c.decode([String].self, forKey: .overlaps)) ?? []
        countInTotals = (try? c.decode(Bool.self, forKey: .countInTotals)) ?? true
        dockerRunning = try? c.decode(Bool.self, forKey: .dockerRunning)
    }

    public var gigabytes: Double { Double(sizeBytes ?? 0) / 1e9 }
}

/// scans/history.csv: one row per entry per scan. Used for growth trends.
public enum StorageHistory {
    /// id -> (date, GB) in time order.
    public static func load(_ url: URL) -> [String: [(Date, Double)]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var out: [String: [(Date, Double)]] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let gb = Double(f[2]), let date = StorageScan.parseDate(String(f[0])) else { continue }
            out[String(f[1]), default: []].append((date, gb))
        }
        return out.mapValues { $0.sorted { $0.0 < $1.0 } }
    }

    /// Change in GB over the last `days`, from the oldest sample in that window.
    public static func growth(_ series: [(Date, Double)], days: Double, now: Date = Date()) -> Double? {
        let start = now.addingTimeInterval(-days * 86400)
        guard let last = series.last, let first = series.first(where: { $0.0 >= start }), first.0 < last.0 else { return nil }
        return last.1 - first.1
    }
}
