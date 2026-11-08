import Foundation

public enum LogLevel: Int, Sendable, Comparable, CaseIterable, Codable {
    case verbose, debug, info, warn, error, fatal

    public init?(letter: Character) {
        switch letter {
        case "V": self = .verbose
        case "D": self = .debug
        case "I": self = .info
        case "W": self = .warn
        case "E": self = .error
        case "F", "A": self = .fatal
        default: return nil
        }
    }

    public var letter: String { ["V", "D", "I", "W", "E", "F"][rawValue] }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What `LogClassifier` recognised in a line (requirements 4.3).
public enum LogKind: String, Sendable, Codable, CaseIterable {
    case plain
    case javaCrash
    case stackFrame
    case anr
    case nativeCrash
    case flutterError
    case dartFrame
    case flutterOutput
    case vmService
    case json

    /// The `is:` name a filter uses.
    public var filterName: String {
        switch self {
        case .plain: "plain"
        case .javaCrash, .nativeCrash: "crash"
        case .stackFrame, .dartFrame: "stacktrace"
        case .anr: "anr"
        case .flutterError: "flutter-error"
        case .flutterOutput: "flutter"
        case .vmService: "vm-service"
        case .json: "json"
        }
    }
}

/// One logcat line, parsed and classified.
public struct LogEntry: Sendable, Equatable, Identifiable {
    /// Increasing per stream: the order lines arrived in.
    public let id: Int
    /// Seconds since 1970 (logcat prints no year: the current one is assumed).
    public let time: TimeInterval
    public let level: LogLevel
    /// The UID; names logcat prints ("system", "shell", "u0_a123") are turned into numbers.
    public let uid: Int?
    public let pid: Int
    public let tid: Int
    public let tag: String
    public let message: String
    public var kind: LogKind = .plain
    /// Flutter errors logged at Info count as errors: colour and level filter use this.
    public var effectiveLevel: LogLevel
    /// The id of the first line of the group (a crash and its frames) this line is in.
    public var group: Int?

    public init(id: Int, time: TimeInterval, level: LogLevel, uid: Int?, pid: Int, tid: Int, tag: String, message: String) {
        self.id = id
        self.time = time
        self.level = level
        self.uid = uid
        self.pid = pid
        self.tid = tid
        self.tag = tag
        self.message = message
        self.effectiveLevel = level
    }
}

/// `logcat -v threadtime -v uid` lines:
/// "11-08 00:02:44.264  1000 19501 19505 I bauth_Service: message".
public struct LogParser: Sendable {
    public static let maxMessage = 4000

    private var nextID = 0
    private let year: Int
    private let calendar: Calendar
    /// Midnight of each "MM-DD" seen, so dates are not computed per line.
    private var days: [Int: TimeInterval] = [:]

    public init(now: Date = Date(), calendar: Calendar = .current) {
        self.calendar = calendar
        year = calendar.component(.year, from: now)
    }

    /// nil for lines that are not log lines ("--------- beginning of main", garbage).
    public mutating func parse(_ line: Substring) -> LogEntry? {
        let u = Array(line.utf8.prefix(Self.maxMessage + 200))
        // "MM-DD HH:MM:SS.mmm" is 18 bytes, then fields separated by spaces.
        guard u.count > 20, u[2] == 0x2D, u[5] == 0x20, u[8] == 0x3A, u[11] == 0x3A, u[14] == 0x2E,
              let month = num(u, 0, 2), let day = num(u, 3, 2), let h = num(u, 6, 2), let m = num(u, 9, 2),
              let s = num(u, 12, 2), let ms = num(u, 15, 3), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var i = 18
        func field() -> Substring? {
            while i < u.count, u[i] == 0x20 { i += 1 }
            let start = i
            while i < u.count, u[i] != 0x20 { i += 1 }
            return start < i ? Substring(decoding: u[start..<i], as: UTF8.self) : nil
        }
        guard let uidField = field(), let pidField = field(), let tidField = field(), let levelField = field(),
              levelField.count == 1, let level = LogLevel(letter: levelField.first!),
              let pid = Int(pidField), let tid = Int(tidField) else { return nil }
        // The tag runs to the first ": " (tags may hold spaces, padded before the colon).
        let rest = String(decoding: u[min(i + 1, u.count)...], as: UTF8.self)
        let tag: String, message: String
        if let colon = rest.range(of: ": ") {
            tag = rest[..<colon.lowerBound].trimmingCharacters(in: .whitespaces)
            message = String(rest[colon.upperBound...])
        } else if rest.hasSuffix(":") {
            tag = String(rest.dropLast()).trimmingCharacters(in: .whitespaces)
            message = ""
        } else {
            tag = rest.trimmingCharacters(in: .whitespaces)
            message = ""
        }
        let midnight = dayStart(month: month, day: day)
        let time = midnight + Double(h * 3600 + m * 60 + s) + Double(ms) / 1000
        defer { nextID += 1 }
        return LogEntry(id: nextID, time: time, level: level, uid: Self.uid(uidField), pid: pid, tid: tid,
                        tag: String(tag.prefix(128)), message: String(message.prefix(Self.maxMessage)))
    }

    private mutating func dayStart(month: Int, day: Int) -> TimeInterval {
        let key = month * 100 + day
        if let t = days[key] { return t }
        let t = calendar.date(from: DateComponents(year: year, month: month, day: day))?.timeIntervalSince1970 ?? 0
        if days.count > 400 { days.removeAll() }
        days[key] = t
        return t
    }

    private func num(_ u: [UInt8], _ at: Int, _ len: Int) -> Int? {
        var v = 0
        for k in at..<(at + len) {
            guard k < u.count, u[k] >= 0x30, u[k] <= 0x39 else { return nil }
            v = v * 10 + Int(u[k] - 0x30)
        }
        return v
    }

    /// Numbers as printed; Android's names for system UIDs; "u0_a123" for apps.
    static func uid(_ s: Substring) -> Int? {
        if let n = Int(s) { return n }
        switch s {
        case "root": return 0
        case "system": return 1000
        case "radio": return 1001
        case "bluetooth": return 1002
        case "wifi": return 1010
        case "media": return 1013
        case "gps": return 1021
        case "nfc": return 1027
        case "logd": return 1036
        case "audioserver": return 1041
        case "cameraserver": return 1047
        case "shell": return 2000
        case "nobody": return 9999
        default: break
        }
        // u<user>_a<app>: 100000 * user + 10000 + app
        guard s.hasPrefix("u"), let us = s.firstIndex(of: "_"), let user = Int(s[s.index(after: s.startIndex)..<us]) else { return nil }
        let rest = s[s.index(after: us)...]
        if rest.hasPrefix("a"), let app = Int(rest.dropFirst()) { return user * 100_000 + 10_000 + app }
        if rest.hasPrefix("i"), let iso = Int(rest.dropFirst()) { return user * 100_000 + 90_000 + iso }
        return nil
    }
}
