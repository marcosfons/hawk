import Foundation

/// The logcat filter (requirements 4.2): what the filter bar says and the chips show,
/// one value. Terms separated by spaces must all match; `|` separates alternatives.
public struct LogFilter: Sendable, Equatable {
    public enum Key: String, Sendable, CaseIterable {
        case package, tag, tagExact = "tag=", tagRegex = "tag~", level, pid, process
        case message, messageRegex = "message~", kind = "is", age
    }

    public struct Term: Sendable, Equatable {
        public var key: Key?          // nil: free text
        public var value: String
        public var negated = false

        public init(_ key: Key?, _ value: String, negated: Bool = false) {
            self.key = key
            self.value = value
            self.negated = negated
        }

        var text: String {
            let v = value.contains(" ") ? "\"\(value)\"" : value
            return (negated ? "-" : "") + (key.map { "\($0.rawValue):" } ?? "") + v
        }
    }

    /// OR of ANDs; one empty alternative matches everything.
    public private(set) var alternatives: [[Term]] = [[]]
    /// Tokens that could not be understood: shown red, ignored.
    public private(set) var invalid: [String] = []

    public init() {}

    public static let kinds = ["crash", "anr", "stacktrace", "flutter-error", "flutter", "vm-service", "json"]

    // MARK: - Text

    public init(parsing text: String) {
        alternatives = []
        var current: [Term] = []
        for token in Self.tokens(text) {
            if token == "|" {
                alternatives.append(current)
                current = []
                continue
            }
            if let term = Self.term(token) { current.append(term) } else { invalid.append(token) }
        }
        alternatives.append(current)
        if alternatives.allSatisfy(\.isEmpty) { alternatives = [[]] }
    }

    public var text: String {
        alternatives.map { $0.map(\.text).joined(separator: " ") }.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        for ch in text.prefix(2000) {
            if ch == "\"" { quoted.toggle(); continue }
            if ch.isWhitespace, !quoted {
                if !current.isEmpty { out.append(current); current = "" }
                continue
            }
            current.append(ch)
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// nil when the token is a known key with a value that cannot work.
    static func term(_ token: String) -> Term? {
        var t = Substring(token)
        let negated = t.hasPrefix("-") && t.count > 1
        if negated { t = t.dropFirst() }
        guard let colon = t.firstIndex(of: ":"), let key = Key(rawValue: String(t[..<colon])) else {
            return Term(nil, String(t), negated: negated)
        }
        let value = String(t[t.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        switch key {
        case .level: guard Self.level(value) != nil else { return nil }
        case .pid: guard Int(value) != nil else { return nil }
        case .age: guard Self.seconds(value) != nil else { return nil }
        case .kind: guard kinds.contains(value) else { return nil }
        case .tagRegex, .messageRegex: guard (try? Regex(value)) != nil else { return nil }
        case .package: guard value == "mine" || ShellQuote.isPackageName(value) || value == "android" else { return nil }
        default: break
        }
        return Term(key, value, negated: negated)
    }

    static func level(_ s: String) -> LogLevel? {
        switch s.lowercased() {
        case "v", "verbose": .verbose
        case "d", "debug": .debug
        case "i", "info": .info
        case "w", "warn", "warning": .warn
        case "e", "error": .error
        case "f", "fatal", "a", "assert": .fatal
        default: nil
        }
    }

    /// "30s", "5m", "2h", "1d".
    static func seconds(_ s: String) -> TimeInterval? {
        guard let unit = s.last, let n = Double(s.dropLast()), n > 0 else { return nil }
        switch unit {
        case "s": return n
        case "m": return n * 60
        case "h": return n * 3600
        case "d": return n * 86_400
        default: return nil
        }
    }

    // MARK: - Chips (they edit the same value)

    /// The minimum level, when every alternative sets the same one.
    public var minimumLevel: LogLevel? {
        let levels = alternatives.map { $0.first { $0.key == .level && !$0.negated }.flatMap { Self.level($0.value) } }
        guard let first = levels.first, levels.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// Packages picked as chips (positive package terms in any alternative).
    public var packages: [String] {
        var seen: [String] = []
        for alt in alternatives { for t in alt where t.key == .package && !t.negated && !seen.contains(t.value) { seen.append(t.value) } }
        return seen
    }

    public func has(kind: String) -> Bool { alternatives.contains { $0.contains(Term(.kind, kind)) } }

    /// Sets (or clears) the minimum level in every alternative.
    public func setting(minimumLevel level: LogLevel?) -> LogFilter {
        var f = self
        f.alternatives = alternatives.map { alt in
            var a = alt.filter { $0.key != .level || $0.negated }
            if let level { a.insert(Term(.level, ["verbose", "debug", "info", "warn", "error", "fatal"][level.rawValue]), at: 0) }
            return a
        }
        return f
    }

    /// Adds an app (as its own alternative, so several apps are shown together) or
    /// removes it.
    public func toggling(package name: String) -> LogFilter {
        var f = self
        let term = Term(.package, name)
        if packages.contains(name) {
            f.alternatives = alternatives.map { $0.filter { $0 != term } }
            f.alternatives = f.alternatives.enumerated().filter { !$0.element.isEmpty || $0.offset == 0 }.map(\.element)
        } else {
            // Every other term applies to the new app too.
            let shared = alternatives.first?.filter { $0.key != .package } ?? []
            if f.alternatives == [[]] || (f.alternatives.count == 1 && !alternatives[0].contains { $0.key == .package }) {
                f.alternatives = [shared + [term]]
            } else {
                f.alternatives.append(shared + [term])
            }
        }
        if f.alternatives.isEmpty { f.alternatives = [[]] }
        return f
    }

    /// Adds or removes an `is:` term in every alternative.
    public func toggling(kind: String) -> LogFilter {
        var f = self
        let term = Term(.kind, kind)
        let on = has(kind: kind)
        f.alternatives = alternatives.map { on ? $0.filter { $0 != term } : $0 + [term] }
        return f
    }

    // MARK: - Matching

    /// What a line is matched against besides itself. Built once per batch.
    public struct Context: Sendable {
        /// UID -> packages (from the package index).
        public var uidPackages: [Int: [String]] = [:]
        /// PID -> process name (from process start lines).
        public var pidProcess: [Int: String] = [:]
        /// "package:mine": apps marked as mine and debuggable ones.
        public var mine: Set<String> = []
        public var now: TimeInterval = 0
        /// Tags always hidden.
        public var muted: Set<String> = []
        public init() {}
    }

    /// The filter with its regexes compiled: build once, match many lines.
    public struct Compiled: @unchecked Sendable {
        // Regex is not Sendable; a Compiled value is built and used on one actor.
        fileprivate let alternatives: [[(Term, Regex<AnyRegexOutput>?)]]

        public func matches(_ e: LogEntry, _ c: Context) -> Bool {
            if !c.muted.isEmpty, c.muted.contains(e.tag) { return false }
            return alternatives.contains { alt in alt.allSatisfy { term, regex in LogFilter.matches(term, regex, e, c) != term.negated } }
        }
    }

    public func compiled() -> Compiled {
        Compiled(alternatives: alternatives.map { alt in
            alt.map { t in (t, t.key == .tagRegex || t.key == .messageRegex ? (try? Regex(t.value))?.ignoresCase() : nil) }
        })
    }

    static func matches(_ t: Term, _ regex: Regex<AnyRegexOutput>?, _ e: LogEntry, _ c: Context) -> Bool {
        switch t.key {
        case nil:
            return e.message.localizedCaseInsensitiveContains(t.value) || e.tag.localizedCaseInsensitiveContains(t.value)
        case .package:
            let packages = (e.uid.flatMap { c.uidPackages[$0] } ?? []) + (c.pidProcess[e.pid].map { [String($0.split(separator: ":").first ?? "")] } ?? [])
            return t.value == "mine" ? packages.contains { c.mine.contains($0) } : packages.contains(t.value)
        case .tag: return e.tag.localizedCaseInsensitiveContains(t.value)
        case .tagExact: return e.tag == t.value
        case .tagRegex: return regex.map { e.tag.contains($0) } ?? false
        case .level: return level(t.value).map { e.effectiveLevel >= $0 } ?? true
        case .pid: return Int(t.value) == e.pid
        case .process: return c.pidProcess[e.pid] == t.value
        case .message: return e.message.localizedCaseInsensitiveContains(t.value)
        case .messageRegex: return regex.map { e.message.contains($0) } ?? false
        case .kind:
            switch t.value {
            case "crash": return e.kind == .javaCrash || e.kind == .nativeCrash || (e.group != nil && [.stackFrame].contains(e.kind) && e.effectiveLevel >= .error)
            case "stacktrace": return e.kind == .stackFrame || e.kind == .dartFrame
            default: return e.kind.filterName == t.value || (t.value == "flutter-error" && e.kind == .dartFrame && e.effectiveLevel >= .error)
            }
        case .age: return seconds(t.value).map { c.now - e.time <= $0 } ?? true
        }
    }
}
