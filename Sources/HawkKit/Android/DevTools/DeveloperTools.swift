import Foundation

/// A developer setting with an off and an on value (requirements 14.2).
public struct DevToggle: Sendable, Equatable, Identifiable {
    public enum Store: Sendable, Equatable {
        /// `settings get/put <namespace> <key>`.
        case setting(namespace: String, key: String)
        /// `cmd uimode night yes|no`.
        case nightMode
    }

    public let id: String
    public let title: String
    public let store: Store
    public let off: String
    public let on: String

    public static let all: [DevToggle] = [
        DevToggle(id: "animations", title: "Animations off", store: .setting(namespace: "global", key: "animator_duration_scale"), off: "1.0", on: "0.0"),
        DevToggle(id: "window-animations", title: "Window animations off", store: .setting(namespace: "global", key: "window_animation_scale"), off: "1.0", on: "0.0"),
        DevToggle(id: "transitions", title: "Transitions off", store: .setting(namespace: "global", key: "transition_animation_scale"), off: "1.0", on: "0.0"),
        DevToggle(id: "taps", title: "Show taps", store: .setting(namespace: "system", key: "show_touches"), off: "0", on: "1"),
        DevToggle(id: "pointer", title: "Pointer location", store: .setting(namespace: "system", key: "pointer_location"), off: "0", on: "1"),
        DevToggle(id: "awake", title: "Stay awake while charging", store: .setting(namespace: "global", key: "stay_on_while_plugged_in"), off: "0", on: "7"),
        DevToggle(id: "dark", title: "Dark mode", store: .nightMode, off: "no", on: "yes"),
        DevToggle(id: "font", title: "Large font (1.3)", store: .setting(namespace: "system", key: "font_scale"), off: "1.0", on: "1.3"),
    ]

    public var read: String {
        switch store {
        case .setting(let ns, let key): "settings get \(ns) \(key)"
        case .nightMode: "cmd uimode night"
        }
    }

    /// The command that sets `value`; nil for a value that is not plain.
    public func write(_ value: String) -> String? {
        guard value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }), value.count <= 16 else { return nil }
        switch store {
        case .setting(let ns, let key): return value == "null" ? "settings delete \(ns) \(key)" : "settings put \(ns) \(key) \(value)"
        case .nightMode: return "cmd uimode night \(value)"
        }
    }

    /// The value now from the read command's output ("Night mode: yes", "0.0", "null").
    public func value(from output: String) -> String {
        let t = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if case .nightMode = store { return t.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? t }
        return t.isEmpty ? "null" : String(t.prefix(16))
    }

    public func isOn(_ value: String) -> Bool {
        if let a = Double(value), let b = Double(on) { return a == b }
        return value == on
    }
}

public enum DevCommands {
    /// Opens a URL or deep link: `am start -a VIEW -d <url>`, optionally in one app.
    public static func open(_ url: String, package: String? = nil) -> String? {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty, u.count <= 2000, !u.contains(where: \.isNewline), u.contains(":") else { return nil }
        var cmd = "am start -a android.intent.action.VIEW -d \(ShellQuote.quote(u))"
        if let package {
            guard let p = ShellQuote.package(package) else { return nil }
            cmd += " \(p)"
        }
        return cmd
    }

    /// Types into the focused field: `input text` wants spaces as %s; the rest is quoted.
    public static func type(_ text: String) -> String? {
        let t = text.replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty, t.count <= 1000 else { return nil }
        return "input text \(ShellQuote.quote(t.replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: " ", with: "%s")))"
    }

    /// The newest Dart VM service URL in the phone's log buffer (no stream).
    public static let findVMService = "logcat -d -v brief -s flutter | grep -o 'http://127.0.0.1:[0-9]*/[^ ]*' | tail -n 1"

    /// "http://127.0.0.1:43123/AbCd=/" -> (43123, "/AbCd=/").
    public static func vmService(_ output: String) -> (port: Int, path: String)? {
        guard let line = output.split(whereSeparator: \.isNewline).last, let url = URL(string: String(line).trimmingCharacters(in: .whitespaces)),
              url.host == "127.0.0.1", let port = url.port, (1...65535).contains(port) else { return nil }
        return (port, url.path.isEmpty ? "/" : url.path + (url.path.hasSuffix("/") ? "" : "/"))
    }
}
