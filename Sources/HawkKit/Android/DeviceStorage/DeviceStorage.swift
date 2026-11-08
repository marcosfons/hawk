import Foundation

/// A device's storage (requirements 6), from one shell batch: `dumpsys diskstats`
/// (classes and per-app sizes, about 13 ms of phone CPU: it reads a cached file),
/// `df -k` (every mounted volume) and `/sys/block` (UFS or eMMC). `sm list-volumes`
/// is left out: it starts app_process, about 180 ms a call.
public struct DeviceStorage: Sendable, Equatable, Codable {
    public enum Class: String, Sendable, Codable, CaseIterable {
        case apps, appData, appCache, photos, videos, audio, downloads, system, other

        public var title: String {
            switch self {
            case .apps: "Apps"
            case .appData: "App data"
            case .appCache: "App cache"
            case .photos: "Photos"
            case .videos: "Videos"
            case .audio: "Audio"
            case .downloads: "Downloads"
            case .system: "System"
            case .other: "Other"
            }
        }

        var diskstatsKey: String {
            switch self {
            case .apps: "App Size"
            case .appData: "App Data Size"
            case .appCache: "App Cache Size"
            case .photos: "Photos Size"
            case .videos: "Videos Size"
            case .audio: "Audio Size"
            case .downloads: "Downloads Size"
            case .system: "System Size"
            case .other: "Other Size"
            }
        }
    }

    public struct AppSize: Sendable, Equatable, Codable {
        public let package: String
        public let app: Int64
        public let data: Int64
        public let cache: Int64
        public var total: Int64 { app + data + cache }
    }

    public struct Volume: Sendable, Equatable, Codable {
        public let mount: String
        public let total: Int64
        public let used: Int64
        public let free: Int64

        /// "Internal", "SD card or USB drive", or the mount point.
        public var kind: String {
            if mount == "/data" || mount.hasPrefix("/data/") || mount == "/storage/emulated" { return "Internal" }
            if mount.hasPrefix("/storage/") || mount.hasPrefix("/mnt/media_rw/") { return "SD card or USB drive" }
            return mount
        }
    }

    public var dataTotal: Int64?
    public var dataFree: Int64?
    public var classes: [Class: Int64] = [:]
    public var apps: [AppSize] = []
    public var volumes: [Volume] = []
    /// "UFS", "eMMC", or nil when the block names do not say.
    public var storageType: String?
    public var hasCardSlotInUse = false
    public var fileBasedEncryption: Bool?

    public init() {}

    public static let parts: [String: String] = [
        "diskstats": "dumpsys diskstats",
        "df": "df -k",
        "block": "ls /sys/block",
    ]

    public static let maxApps = 5000

    public static func parse(_ parts: [String: String]) -> DeviceStorage {
        var s = DeviceStorage()
        let lines = (parts["diskstats"] ?? "").prefix(4 << 20).split(whereSeparator: \.isNewline)
        var arrays: [String: Substring] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if key == "Data-Free" {
                // "14117936K / 234936320K total = 6% free"
                let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Int64($0) }
                if numbers.count >= 2 { s.dataFree = numbers[0] * 1024; s.dataTotal = numbers[1] * 1024 }
            } else if key == "File-based Encryption" {
                s.fileBasedEncryption = value == "true"
            } else if let c = Class.allCases.first(where: { $0.diskstatsKey == key }), let n = Int64(value), n >= 0 {
                s.classes[c] = n
            } else if ["Package Names", "App Sizes", "App Data Sizes", "Cache Sizes"].contains(key) {
                arrays[key] = line[line.index(after: colon)...]
            }
        }
        let names = jsonArray(arrays["Package Names"]) as? [String] ?? []
        let sizes = (jsonArray(arrays["App Sizes"]) as? [NSNumber] ?? []).map(\.int64Value)
        let data = (jsonArray(arrays["App Data Sizes"]) as? [NSNumber] ?? []).map(\.int64Value)
        let cache = (jsonArray(arrays["Cache Sizes"]) as? [NSNumber] ?? []).map(\.int64Value)
        let n = min(names.count, sizes.count, data.count, cache.count, maxApps)
        s.apps = (0..<n).compactMap { i in
            guard ShellQuote.isPackageName(names[i]) || names[i] == "android", sizes[i] >= 0, data[i] >= 0, cache[i] >= 0 else { return nil }
            return AppSize(package: names[i], app: sizes[i], data: data[i], cache: cache[i])
        }
        s.volumes = parseDf(parts["df"] ?? "")
        let blocks = Set((parts["block"] ?? "").split(whereSeparator: { $0.isWhitespace }).map(String.init).prefix(1000))
        let ufs = blocks.contains { $0.count == 3 && $0.hasPrefix("sd") }
        let mmc = blocks.filter { $0.hasPrefix("mmcblk") && !$0.contains("p") && !$0.contains("boot") && !$0.contains("rpmb") }
        if ufs {
            s.storageType = "UFS"
            s.hasCardSlotInUse = !mmc.isEmpty
        } else if mmc.contains("mmcblk0") {
            s.storageType = "eMMC"
            s.hasCardSlotInUse = mmc.count > 1
        }
        return s
    }

    /// The apps using the most, app + data + cache.
    public func biggest(_ count: Int) -> [AppSize] {
        Array(apps.sorted { $0.total > $1.total }.prefix(count))
    }

    /// `df -k`: internal storage and removable volumes, without system mounts and
    /// duplicates of the same filesystem (the same data partition shows several times).
    static func parseDf(_ text: String) -> [Volume] {
        var out: [Volume] = []
        var seen = Set<String>()
        for line in text.prefix(256 * 1024).split(whereSeparator: \.isNewline).prefix(2000).dropFirst() {
            let f = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard f.count >= 6, let total = Int64(f[1]), let used = Int64(f[2]), let free = Int64(f[3]), total > 0 else { continue }
            let mount = String(f[5...].joined(separator: " "))
            let interesting = mount == "/data" || mount == "/storage/emulated" || mount.hasPrefix("/storage/") && mount != "/storage/self"
                || mount.hasPrefix("/mnt/media_rw/")
            // /data and /storage/emulated are the same storage through two filesystems.
            let key = "\(total) \(used)"
            guard interesting, seen.insert(key).inserted else { continue }
            out.append(Volume(mount: mount, total: total * 1024, used: used * 1024, free: free * 1024))
        }
        return out
    }

    private static func jsonArray(_ text: Substring?) -> Any? {
        guard let text, text.utf8.count < 4 << 20 else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }
}
