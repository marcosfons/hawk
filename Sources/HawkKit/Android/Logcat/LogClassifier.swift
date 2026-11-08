import Foundation

/// Recognises crashes, stack traces, ANRs, native crashes, Flutter errors, Dart
/// stacks, Flutter output, the Dart VM service URL and JSON (requirements 4.3), and
/// groups a crash with the lines that belong to it. Runs on every line, so each rule
/// is a few prefix or substring checks; adding a kind is one rule and one test.
public struct LogClassifier: Sendable {
    /// The open group per (pid, tag): the crash its next frames belong to.
    private var open: [Key: Group] = [:]

    private struct Key: Hashable { let pid: Int; let tag: String }
    private struct Group { let id: Int; let kind: LogKind; var lines: Int }

    /// A group stops taking lines after this many, so a runaway one cannot grow forever.
    static let maxGroup = 500

    public init() {}

    public mutating func classify(_ e: inout LogEntry) {
        let key = Key(pid: e.pid, tag: e.tag)
        let m = e.message
        let start = Self.groupStart(e)
        if let kind = start {
            e.kind = kind
            e.group = e.id
            open[key] = Group(id: e.id, kind: kind, lines: 1)
            if open.count > 256 { open.removeAll(keepingCapacity: true); open[key] = Group(id: e.id, kind: kind, lines: 1) }
        } else if var g = open[key], g.lines < Self.maxGroup, Self.continues(g.kind, e) {
            g.lines += 1
            open[key] = g
            e.group = g.id
            e.kind = Self.isDartFrame(m) ? .dartFrame : Self.isJavaFrame(m) ? .stackFrame : g.kind
            // A Flutter error block ends at its closing rule.
            if g.kind == .flutterError, m.hasPrefix("════════") { open[key] = nil }
        } else {
            open[key] = nil
            e.kind = Self.single(e)
        }
        // A crash and every frame grouped under it count as errors (Flutter logs its
        // errors at Info); a frame on its own keeps its level.
        if [.javaCrash, .anr, .nativeCrash, .flutterError].contains(e.kind) || (e.group != nil && e.kind != .plain) {
            e.effectiveLevel = max(e.level, .error)
        }
    }

    /// A line that opens a group.
    static func groupStart(_ e: LogEntry) -> LogKind? {
        let m = e.message
        if e.tag == "AndroidRuntime", m.hasPrefix("FATAL EXCEPTION") { return .javaCrash }
        if e.tag == "ActivityManager", m.hasPrefix("ANR in ") { return .anr }
        if (e.tag == "DEBUG" || e.tag == "crash_dump" || e.tag == "libc"), m.contains("*** *** *** ***") { return .nativeCrash }
        if e.tag == "flutter" || e.tag.hasPrefix("flutter") {
            if m.contains("══╡ EXCEPTION CAUGHT BY") { return .flutterError }
            if m.contains("Unhandled Exception:") { return .flutterError }
        }
        return nil
    }

    /// Whether a line belongs to an open group of `kind` from the same pid and tag.
    static func continues(_ kind: LogKind, _ e: LogEntry) -> Bool {
        switch kind {
        case .javaCrash, .anr, .nativeCrash, .flutterError: true
        default: isJavaFrame(e.message) || isDartFrame(e.message)
        }
    }

    /// A line on its own.
    static func single(_ e: LogEntry) -> LogKind {
        let m = e.message
        if isJavaFrame(m) { return .stackFrame }
        if isDartFrame(m) { return .dartFrame }
        if e.tag == "flutter" {
            if m.contains("The Dart VM service is listening on http") { return .vmService }
            if e.level >= .error { return .flutterError }
            return .flutterOutput
        }
        if m.contains("The Dart VM service is listening on http") { return .vmService }
        let t = m.trimmingCharacters(in: .whitespaces)
        if t.count >= 2, (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("[") && t.hasSuffix("]") && t.contains("\"")) { return .json }
        return .plain
    }

    /// "\tat com.example.Foo.bar(Foo.java:12)", "Caused by: ...", "\t... 7 more".
    static func isJavaFrame(_ m: String) -> Bool {
        let t = m.drop { $0 == " " || $0 == "\t" }
        if t.hasPrefix("at "), t.hasSuffix(")"), t.contains("(") { return true }
        if t.hasPrefix("Caused by: ") { return true }
        if t.hasPrefix("... "), t.hasSuffix(" more") { return true }
        return false
    }

    /// "#0      main (package:app/main.dart:12:3)", "#12 _rootRun (dart:async/zone.dart:1399:13)".
    static func isDartFrame(_ m: String) -> Bool {
        let t = m.drop { $0 == " " }
        guard t.hasPrefix("#"), let space = t.firstIndex(of: " "), t[t.index(after: t.startIndex)..<space].allSatisfy(\.isNumber) else { return false }
        return t.contains("(package:") || t.contains("(dart:") || t.contains("(file:")
    }

    /// A frame from the app's own code (shown bright; framework frames dim).
    public static func isAppFrame(_ message: String, packages: [String]) -> Bool {
        let t = message.drop { $0 == " " || $0 == "\t" }
        for p in packages where !p.isEmpty {
            if t.hasPrefix("at \(p).") { return true }
            // Dart: package:<name>/ where the name is the package's last segment.
            if let last = p.split(separator: ".").last, t.contains("(package:\(last)/") { return true }
        }
        return false
    }

    /// The URL of the Dart VM service in a line, for the DevTools button.
    public static func vmServiceURL(_ message: String) -> URL? {
        guard let r = message.range(of: "http://127.0.0.1:") ?? message.range(of: "http://") else { return nil }
        let url = message[r.lowerBound...].prefix { !$0.isWhitespace }
        return URL(string: String(url))
    }

    /// "Start proc 12345:com.example.app/u0a123 for ..." from ActivityManager: a new
    /// PID for a process, so a package filter keeps following the app.
    public static func processStart(_ e: LogEntry) -> (pid: Int, process: String)? {
        guard e.tag == "ActivityManager", e.message.hasPrefix("Start proc ") else { return nil }
        let rest = e.message.dropFirst("Start proc ".count)
        guard let colon = rest.firstIndex(of: ":"), let pid = Int(rest[..<colon]) else { return nil }
        let process = rest[rest.index(after: colon)...].prefix { $0 != "/" && $0 != " " }
        return process.isEmpty ? nil : (pid, String(process.prefix(128)))
    }
}
