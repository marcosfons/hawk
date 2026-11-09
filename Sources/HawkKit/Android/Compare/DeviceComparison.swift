import Foundation

/// Two devices side by side (requirements 14.3): system and app versions from what
/// Hawk already keeps for each (so a disconnected device compares too, and the phone
/// does nothing), and settings read on demand from both while they are connected.
public enum DeviceComparison {
    public struct Row: Sendable, Equatable, Identifiable {
        public let label: String
        public let a: String
        public let b: String
        public var id: String { label }
        public var differs: Bool { a != b }
    }

    // MARK: System

    public static func system(_ a: SystemInfo?, _ b: SystemInfo?) -> [Row] {
        func row(_ label: String, _ value: (SystemInfo) -> String?) -> Row {
            Row(label: label, a: a.flatMap(value) ?? "-", b: b.flatMap(value) ?? "-")
        }
        func android(_ s: SystemInfo) -> String? {
            guard let release = s.android else { return nil }
            return s.sdk.map { "\(release) (SDK \($0))" } ?? release
        }
        return [
            row("Manufacturer", \.manufacturer),
            row("Model", \.model),
            row("Android", android),
            row("Build", \.build),
            row("Security patch", \.securityPatch),
            row("Chip", \.soc),
            row("ABIs", \.abis),
            row("RAM") { $0.ramKB.map { Format.bytes(Double($0) * 1024) } },
            row("Display") { $0.displaySize },
            row("Density") { $0.density },
            row("Kernel") { $0.kernel },
            row("SELinux") { $0.selinux },
            row("Encryption", \.encryption),
            row("Bootloader") { $0.bootloaderLocked.map { $0 ? "Locked" : "Unlocked" } },
            row("Verified boot", \.verifiedBoot),
            row("Root signs") { $0.rootIndicators.isEmpty ? "None" : $0.rootIndicators.joined(separator: ", ") },
        ]
    }

    // MARK: Apps

    public struct AppRow: Sendable, Equatable, Identifiable {
        public enum Kind: Int, Sendable, Comparable {
            case differs, onlyA, onlyB, same
            public static func < (l: Kind, r: Kind) -> Bool { l.rawValue < r.rawValue }
        }
        public let name: String
        public let label: String
        /// The version on each device, nil when it is not installed there.
        public let a: String?
        public let b: String?
        public let kind: Kind
        public var id: String { name }
    }

    /// Every app on either device: different versions first, then those on only one,
    /// then the same, each by label. System apps only when asked for.
    public static func apps(_ a: [AppEntry], _ b: [AppEntry], includeSystem: Bool) -> [AppRow] {
        func index(_ list: [AppEntry]) -> [String: AppEntry] {
            Dictionary(list.prefix(10_000).filter { includeSystem || !$0.isSystem }.map { ($0.name, $0) }, uniquingKeysWith: { x, _ in x })
        }
        let ia = index(a), ib = index(b)
        let rows = Set(ia.keys).union(ib.keys).map { name -> AppRow in
            let x = ia[name], y = ib[name]
            let kind: AppRow.Kind = switch (x, y) {
            case (nil, _): .onlyB
            case (_, nil): .onlyA
            case let (x?, y?): sameVersion(x, y) ? .same : .differs
            }
            return AppRow(name: name, label: x?.label ?? y?.label ?? name, a: x.map(version), b: y.map(version), kind: kind)
        }
        return rows.sorted {
            $0.kind != $1.kind ? $0.kind < $1.kind
                : $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
        }
    }

    static func sameVersion(_ x: AppEntry, _ y: AppEntry) -> Bool {
        if let cx = x.versionCode, let cy = y.versionCode { return cx == cy }
        return x.versionName == y.versionName
    }

    static func version(_ e: AppEntry) -> String {
        switch (e.versionName, e.versionCode) {
        case let (name?, code?): "\(name) (\(code))"
        case let (name?, nil): name
        case let (nil, code?): "\(code)"
        default: "?"
        }
    }

    // MARK: Settings

    /// The global and system tables. Not secure: it holds identifiers (the Android ID
    /// among them) that have no place in a comparison.
    public static let settingsScript = "echo '[global]'; settings list global 2>/dev/null; echo '[system]'; settings list system 2>/dev/null"

    /// "global/key" -> value, capped (device output is untrusted).
    public static func parseSettings(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        var table = ""
        for line in text.prefix(512 * 1024).split(whereSeparator: \.isNewline).prefix(5000) {
            if line == "[global]" || line == "[system]" { table = String(line.dropFirst().dropLast()); continue }
            guard !table.isEmpty, let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            let key = line[..<eq].prefix(120), value = line[line.index(after: eq)...].prefix(200)
            out["\(table)/\(key)"] = String(value)
        }
        return out
    }

    /// Only the settings that differ, missing on one side shown as "-", by key.
    public static func settings(_ a: [String: String], _ b: [String: String]) -> [Row] {
        Set(a.keys).union(b.keys)
            .compactMap { key in
                let x = a[key] ?? "-", y = b[key] ?? "-"
                return x == y ? nil : Row(label: key, a: x, b: y)
            }
            .sorted { $0.label < $1.label }
    }
}
