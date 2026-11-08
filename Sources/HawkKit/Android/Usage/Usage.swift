import Foundation

/// Battery use per UID since the last full charge, from `dumpsys batterystats
/// --checkin` (about 0.7 MB, 180 ms of phone CPU: read when the page opens and every
/// few minutes while shown). Also its per-UID network totals, the fallback when the
/// helper cannot run.
public struct BatteryCheckin: Sendable, Equatable {
    public var mAh: [Int: Double] = [:]
    /// Battery capacity and the computed drain since the charge, when printed.
    public var capacity: Double?
    public var drain: Double?
    public var network: [Int: (mobile: Int64, wifi: Int64)] = [:]

    public static func == (a: BatteryCheckin, b: BatteryCheckin) -> Bool {
        a.mAh == b.mAh && a.capacity == b.capacity && a.drain == b.drain
            && a.network.mapValues { [$0.mobile, $0.wifi] } == b.network.mapValues { [$0.mobile, $0.wifi] }
    }

    public static let command = "dumpsys batterystats --checkin | grep -E '^9,[0-9]+,l,(pwi|pws|nt),'"

    /// `9,<uid>,l,pwi,uid,<mAh>,...`, `9,0,l,pws,<capacity>,<drain>,...`,
    /// `9,<uid>,l,nt,<mobile rx>,<mobile tx>,<wifi rx>,<wifi tx>,...`.
    public static func parse(_ text: String) -> BatteryCheckin {
        var out = BatteryCheckin()
        for line in text.prefix(8 << 20).split(whereSeparator: \.isNewline).prefix(200_000) {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 6, f[0] == "9", f[2] == "l", let uid = Int(f[1]) else { continue }
            switch f[3] {
            case "pwi" where f[4] == "uid":
                if let v = Double(f[5]), v.isFinite, v >= 0 { out.mAh[uid, default: 0] += v }
            case "pws":
                out.capacity = Double(f[4]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                out.drain = Double(f[5]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            case "nt" where f.count >= 8:
                let n = f[4...7].map { Int64($0) ?? 0 }
                guard n.allSatisfy({ $0 >= 0 }) else { continue }
                out.network[uid] = (mobile: n[0] + n[1], wifi: n[2] + n[3])
            default:
                continue
            }
        }
        return out
    }
}

/// Memory per process now, from `dumpsys meminfo`'s "Total PSS by process".
public enum Meminfo {
    public static let command = "dumpsys meminfo | sed -n '/Total PSS by process/,/^$/p'"

    /// Package -> KB of PSS, processes of one app (":service" suffixes) added up.
    public static func parse(_ text: String) -> [String: Int64] {
        var out: [String: Int64] = [:]
        for line in text.prefix(1 << 20).split(whereSeparator: \.isNewline).prefix(5000) {
            // "    536,438K: com.example.app (pid 31141 / activities)"
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let k = t.range(of: "K: ") else { continue }
            guard let kb = Int64(t[..<k.lowerBound].replacingOccurrences(of: ",", with: "")), kb >= 0 else { continue }
            let process = t[k.upperBound...].split(separator: " ").first.map(String.init) ?? ""
            let package = String(process.split(separator: ":").first ?? "")
            guard ShellQuote.isPackageName(package) else { continue }
            out[package, default: 0] += kb
        }
        return out
    }
}

/// One UID's data on one day.
public struct DayUsage: Sendable, Equatable, Codable {
    public var wifi: Int64 = 0
    public var mobile: Int64 = 0
    public var background: Int64 = 0
    public init(wifi: Int64 = 0, mobile: Int64 = 0, background: Int64 = 0) {
        self.wifi = wifi
        self.mobile = mobile
        self.background = background
    }
}

/// Daily data per UID, kept in the device folder so history grows past the phone's
/// own (about 100 days). Days are local calendar days, keyed "yyyy-MM-dd".
public struct UsageHistory: Sendable, Equatable, Codable {
    public private(set) var days: [String: [Int: DayUsage]] = [:]
    /// The newest day fetched completely (today is always fetched again).
    public private(set) var lastComplete: String?

    public static let maxDays = 400
    public static let firstFetchDays = 100

    public init() {}

    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// What to ask the helper: from the day after the last complete one (or 100 days
    /// back) to now, one window per day.
    public func nextFetch(now: Date, calendar: Calendar = .current) -> HelperCommand {
        let today = calendar.startOfDay(for: now)
        var from = calendar.date(byAdding: .day, value: -Self.firstFetchDays, to: today) ?? today
        if let last = lastComplete, let lastDate = Self.date(last, calendar: calendar),
           let next = calendar.date(byAdding: .day, value: 1, to: lastDate), next > from {
            from = min(next, today)
        }
        return .net(from: from, to: now, step: 86_400)
    }

    /// Replaces the fetched days with what the helper returned; drops the oldest past
    /// `maxDays`.
    public mutating func merge(_ records: [NetRecord], fetched: HelperCommand, now: Date, calendar: Calendar = .current) {
        guard case .net(let from, _, _) = fetched else { return }
        var fresh: [String: [Int: DayUsage]] = [:]
        for r in records {
            var d = fresh[Self.key(r.windowStart, calendar: calendar), default: [:]][r.uid] ?? DayUsage()
            let bytes = r.rx + r.tx
            if r.transport == .wifi { d.wifi += bytes } else { d.mobile += bytes }
            if !r.foreground { d.background += bytes }
            fresh[Self.key(r.windowStart, calendar: calendar), default: [:]][r.uid] = d
        }
        var day = calendar.startOfDay(for: from)
        let today = calendar.startOfDay(for: now)
        while day <= today {
            days[Self.key(day, calendar: calendar)] = fresh[Self.key(day, calendar: calendar)] ?? [:]
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) { lastComplete = Self.key(yesterday, calendar: calendar) }
        if days.count > Self.maxDays {
            for k in days.keys.sorted().prefix(days.count - Self.maxDays) { days[k] = nil }
        }
    }

    /// Totals per UID over the last `count` days including today.
    public func totals(lastDays count: Int, now: Date, calendar: Calendar = .current) -> [Int: DayUsage] {
        var out: [Int: DayUsage] = [:]
        let today = calendar.startOfDay(for: now)
        for i in 0..<max(count, 1) {
            guard let d = calendar.date(byAdding: .day, value: -i, to: today), let day = days[Self.key(d, calendar: calendar)] else { continue }
            for (uid, u) in day {
                var t = out[uid] ?? DayUsage()
                t.wifi += u.wifi
                t.mobile += u.mobile
                t.background += u.background
                out[uid] = t
            }
        }
        return out
    }

    static func date(_ key: String, calendar: Calendar) -> Date? {
        let p = key.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }
}

public enum UsagePeriod: String, Sendable, CaseIterable {
    case today, week, month, sinceCharge

    public var title: String {
        switch self {
        case .today: "Today"
        case .week: "7 days"
        case .month: "30 days"
        case .sinceCharge: "Since charge"
        }
    }

    var days: Int {
        switch self {
        case .today: 1
        case .week: 7
        case .month, .sinceCharge: 30
        }
    }
}

/// One row of the Usage table: an app, a group of apps sharing a UID, or a special
/// UID (removed apps, hotspot).
public struct UsageRow: Sendable, Equatable, Identifiable {
    public let id: Int
    public let title: String
    public let packages: [String]
    public var mAh: Double?
    public var batteryShare: Double?
    public var wifi: Int64?
    public var mobile: Int64?
    public var background: Int64?
    public var memoryKB: Int64?

    public var data: Int64? { wifi == nil && mobile == nil ? nil : (wifi ?? 0) + (mobile ?? 0) }
}

public enum UsageTable {
    /// Rows for a period. Data comes from the helper's history, or, when there is none,
    /// from batterystats' totals since the charge (whatever the period says, and the
    /// caller labels it so). Battery is always since the last charge.
    public static func rows(index: PackageIndex?, history: UsageHistory?, battery: BatteryCheckin?,
                            memory: [String: Int64], period: UsagePeriod, now: Date, calendar: Calendar = .current) -> [UsageRow] {
        var byUID: [Int: UsageRow] = [:]
        func row(_ uid: Int) -> UsageRow {
            if let r = byUID[uid] { return r }
            let packages = index?.packages(uid: uid) ?? []
            return UsageRow(id: uid, title: title(uid: uid, packages: packages, index: index), packages: packages)
        }
        if let history, !history.days.isEmpty {
            for (uid, u) in history.totals(lastDays: period.days, now: now, calendar: calendar) where u.wifi + u.mobile > 0 {
                var r = row(uid)
                r.wifi = u.wifi
                r.mobile = u.mobile
                r.background = u.background
                byUID[uid] = r
            }
        } else if let battery {
            for (uid, n) in battery.network where n.mobile + n.wifi > 0 {
                var r = row(uid)
                r.wifi = n.wifi
                r.mobile = n.mobile
                byUID[uid] = r
            }
        }
        if let battery {
            let total = battery.mAh.values.reduce(0, +)
            for (uid, mAh) in battery.mAh where mAh > 0.01 {
                var r = row(uid)
                r.mAh = mAh
                r.batteryShare = total > 0 ? mAh / total : nil
                byUID[uid] = r
            }
        }
        if let index {
            for (package, kb) in memory {
                guard let uid = index[package]?.uid else { continue }
                var r = row(uid)
                r.memoryKB = (r.memoryKB ?? 0) + kb
                byUID[uid] = r
            }
        }
        return byUID.values.sorted { ($0.mAh ?? 0, $0.data ?? 0) > ($1.mAh ?? 0, $1.data ?? 0) }
    }

    static func title(uid: Int, packages: [String], index: PackageIndex?) -> String {
        switch uid {
        case -5: return "Hotspot"
        case -4: return "Removed apps"
        case 0: return "Android kernel (root)"
        case 1000: return "Android system"
        default: break
        }
        guard let first = packages.first else { return "UID \(uid)" }
        let name = index?[first]?.label ?? first
        return packages.count > 1 ? "\(name) and \(packages.count - 1) more" : name
    }
}
