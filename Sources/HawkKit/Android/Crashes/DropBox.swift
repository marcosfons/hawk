import Foundation

/// A crash or ANR Android recorded in its DropBox (requirements 5, 5.1).
public struct CrashRecord: Sendable, Equatable, Codable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case crash, nativeCrash, anr, watchdog

        public var title: String {
            switch self {
            case .crash: "Crash"
            case .nativeCrash: "Native crash"
            case .anr: "ANR"
            case .watchdog: "System watchdog"
            }
        }
    }

    /// The listing's identity of the entry: date, tag and size.
    public let key: String
    public let tag: String
    public let kind: Kind
    public let date: Date
    public var process: String?
    public var package: String?
    public var pid: Int?
    public var uid: Int?
    public var foreground: Bool?
    /// First line of the reason ("Input dispatching timed out ...", the exception).
    public var reason: String
    /// The trace as Android wrote it (capped).
    public var body: String
    /// For an ANR: logcat lines from the phone's buffer before it (read once).
    public var logcat: [String] = []

    public var id: String { key }

    public init(key: String, tag: String, kind: Kind, date: Date, process: String? = nil, package: String? = nil, pid: Int? = nil,
                uid: Int? = nil, foreground: Bool? = nil, reason: String, body: String) {
        self.key = key
        self.tag = tag
        self.kind = kind
        self.date = date
        self.process = process
        self.package = package
        self.pid = pid
        self.uid = uid
        self.foreground = foreground
        self.reason = reason
        self.body = body
    }
}

public enum DropBox {
    /// Tags Hawk imports, and what each one is.
    public static let tags: [String: CrashRecord.Kind] = [
        "data_app_crash": .crash, "system_app_crash": .crash, "system_server_crash": .crash,
        "data_app_native_crash": .nativeCrash, "system_app_native_crash": .nativeCrash, "SYSTEM_TOMBSTONE": .nativeCrash,
        "data_app_anr": .anr, "system_app_anr": .anr, "system_server_anr": .anr,
        "system_server_watchdog": .watchdog,
    ]

    static let pattern = "^[0-9-]+ [0-9:]+ (" + tags.keys.sorted().joined(separator: "|") + ") "

    /// The full listing, only the tags above (on connection: catches what happened
    /// while the phone was away; about 120 ms of phone CPU).
    public static let fullListing = "dumpsys dropbox 2>/dev/null | grep -E '\(pattern)'"

    /// Today's entries, and yesterday's too for the first minutes after midnight (the
    /// 60 s check: about 60 ms of phone CPU). `dumpsys dropbox <date>` matches the date
    /// as a substring.
    public static let recentListing = "d=$(date +%Y-%m-%d); y=$(date -d @$(( $(date +%s) - 600 )) +%Y-%m-%d); "
        + "for x in $(echo $d $y | tr ' ' '\\n' | sort -u); do dumpsys dropbox $x 2>/dev/null; done | grep -E '\(pattern)'"

    public struct Header: Sendable, Equatable, Hashable {
        public let key: String
        public let tag: String
        public let date: Date
    }

    /// "2026-11-05 08:37:18 data_app_crash (text, 1599 bytes)".
    public static func parseListing(_ text: String, timeZone: TimeZone = .current) -> [Header] {
        var out: [Header] = []
        for line in text.prefix(1 << 20).split(whereSeparator: \.isNewline).prefix(5000) {
            let f = line.split(separator: " ", maxSplits: 3)
            guard f.count >= 3, tags[String(f[2])] != nil, let date = date(String(f[0]) + " " + String(f[1]), timeZone: timeZone) else { continue }
            out.append(Header(key: line.trimmingCharacters(in: .whitespaces), tag: String(f[2]), date: date))
        }
        return out
    }

    /// `dumpsys dropbox --print <tag>`: entries between "=====" lines.
    public static func parseEntries(_ text: String, timeZone: TimeZone = .current) -> [CrashRecord] {
        var out: [CrashRecord] = []
        for block in text.prefix(8 << 20).components(separatedBy: "\n========================================\n").dropFirst().prefix(1000) {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let first = lines.first, let header = parseListing(String(first), timeZone: timeZone).first,
                  let kind = tags[header.tag] else { continue }
            var fields: [String: String] = [:]
            var bodyStart = lines.count
            for (i, line) in lines.enumerated().dropFirst() {
                if line.isEmpty { bodyStart = i + 1; break }
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let body = lines[min(bodyStart, lines.count)...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = fields["Subject"] ?? body.split(separator: "\n").first.map(String.init) ?? ""
            out.append(CrashRecord(
                key: header.key, tag: header.tag, kind: kind,
                date: fields["Timestamp"].flatMap(timestamp) ?? header.date,
                process: fields["Process"].map { String($0.prefix(128)) },
                package: fields["Package"].flatMap { $0.split(separator: " ").first.map(String.init) }.flatMap { ShellQuote.isPackageName($0) ? $0 : nil },
                pid: fields["PID"].flatMap { Int($0) }, uid: fields["UID"].flatMap { Int($0) },
                foreground: fields["Foreground"].map { $0.hasPrefix("Yes") || $0 == "true" },
                reason: String(reason.prefix(300)), body: String(body.prefix(64 * 1024))))
        }
        return out
    }

    /// The logcat lines before an ANR, from the phone's own buffer: no stream.
    public static func logcatBefore(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return "logcat -d -v threadtime -v uid -b main,system,crash -t \(ShellQuote.quote(f.string(from: date.addingTimeInterval(-30)))) | head -n 400"
    }

    static func date(_ s: String, timeZone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)
    }

    /// "2026-11-05 08:37:18.372-0300".
    static func timestamp(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSZ"
        return f.date(from: s)
    }
}

/// What the watcher keeps per device: every record imported (newest 500) and when
/// it started watching, so history found on the first import does not alert.
public struct CrashLog: Sendable, Equatable, Codable {
    public private(set) var records: [CrashRecord] = []
    public private(set) var known: Set<String> = []
    public var since: Date?

    public static let maxRecords = 500

    public init() {}

    /// Headers not imported yet.
    public func new(_ headers: [DropBox.Header]) -> [DropBox.Header] {
        headers.filter { !known.contains($0.key) }
    }

    /// Adds the new records; returns those that deserve an alert (after `since`).
    public mutating func add(_ fetched: [CrashRecord], now: Date) -> [CrashRecord] {
        let start = since ?? now
        if since == nil { since = now }
        let fresh = fetched.filter { !known.contains($0.key) }
        for r in fresh { known.insert(r.key) }
        records = Array((records + fresh).sorted { $0.date > $1.date }.prefix(Self.maxRecords))
        if known.count > Self.maxRecords * 4 { known = Set(records.map(\.key)) }
        return fresh.filter { $0.date >= start.addingTimeInterval(-120) }.sorted { $0.date < $1.date }
    }

    /// Headers seen in a listing but not fetched (a tag Hawk could not read) still count
    /// as known, so they are not fetched every minute.
    public mutating func markKnown(_ headers: [DropBox.Header]) {
        for h in headers { known.insert(h.key) }
    }

    public mutating func setLogcat(_ lines: [String], for key: String) {
        guard let i = records.firstIndex(where: { $0.key == key }) else { return }
        records[i].logcat = Array(lines.prefix(400))
    }

    /// Crash and ANR counts per package.
    public func counts() -> [String: (crashes: Int, anrs: Int)] {
        var out: [String: (crashes: Int, anrs: Int)] = [:]
        for r in records {
            let p = r.package ?? r.process ?? "unknown"
            var c = out[p] ?? (0, 0)
            if r.kind == .anr { c.anrs += 1 } else { c.crashes += 1 }
            out[p] = c
        }
        return out
    }
}
