import Foundation

/// One app as the Apps list shows it: what the shell tells (always), plus what the
/// helper adds when it runs (label, dates, target SDK).
public struct AppEntry: Sendable, Equatable, Identifiable, Codable {
    public let name: String
    public var label: String?
    public var uid: Int?
    public var versionCode: Int64?
    public var versionName: String?
    public var isSystem: Bool
    public var enabled: Bool
    public var installer: String?
    public var firstInstall: Date?
    public var lastUpdate: Date?
    public var targetSdk: Int?
    public var appSize: Int64?
    public var dataSize: Int64?
    public var cacheSize: Int64?

    public var id: String { name }
    public var title: String { label ?? name }
    public var totalSize: Int64? {
        guard appSize != nil || dataSize != nil || cacheSize != nil else { return nil }
        return (appSize ?? 0) + (dataSize ?? 0) + (cacheSize ?? 0)
    }

    /// Where it came from: Play, another store, sideloaded, or preloaded with the system.
    public var source: String {
        switch installer {
        case "com.android.vending": return "Play Store"
        case "com.sec.android.app.samsungapps": return "Galaxy Store"
        case "com.amazon.venezia": return "Amazon Appstore"
        case "org.fdroid.fdroid": return "F-Droid"
        case nil, "": return isSystem ? "Preloaded" : "Sideloaded"
        case "com.android.shell", "com.android.packageinstaller", "com.google.android.packageinstaller": return "Sideloaded"
        case let other?: return other
        }
    }

    /// Key for its cached icon: a new version gets a new icon.
    public var iconKey: String { "\(name)-\(versionCode ?? 0)" }
}

public enum AppFilter: String, Sendable, CaseIterable {
    case all, user, system, disabled, sideloaded

    public var title: String {
        switch self {
        case .all: "All"
        case .user: "User"
        case .system: "System"
        case .disabled: "Disabled"
        case .sideloaded: "Sideloaded"
        }
    }
}

public enum AppCatalog {
    /// Shell reads for the list, besides the package index and diskstats: about 60 ms
    /// of phone CPU each, once when the section opens.
    public static let shellParts: [String: String] = [
        "installers": "pm list packages -i --user 0",
        "disabled": "pm list packages -d --user 0",
    ]

    /// "package:com.example.app  installer=com.android.vending" (installer "null" when none).
    public static func parseInstallers(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in text.prefix(1 << 20).split(whereSeparator: \.isNewline).prefix(10_000) {
            let words = line.split(separator: " ")
            guard let pkg = words.first(where: { $0.hasPrefix("package:") })?.dropFirst(8),
                  let inst = words.first(where: { $0.hasPrefix("installer=") })?.dropFirst(10) else { continue }
            guard ShellQuote.isPackageName(String(pkg)), inst != "null", inst.count <= 128 else { continue }
            out[String(pkg)] = String(inst)
        }
        return out
    }

    public static func parsePackages(_ text: String) -> Set<String> {
        Set(text.prefix(1 << 20).split(whereSeparator: \.isNewline).prefix(10_000).compactMap { line in
            line.hasPrefix("package:") ? String(line.dropFirst(8).split(separator: " ").first ?? "") : nil
        }.filter { ShellQuote.isPackageName($0) || $0 == "android" })
    }

    /// Every app, from the package index and the shell, with the helper's metadata
    /// and sizes merged in where present.
    public static func build(index: PackageIndex, shell: [String: String], helper: [HelperApp] = [],
                             storage: DeviceStorage? = nil) -> [AppEntry] {
        let installers = parseInstallers(shell["installers"] ?? "")
        let disabled = parsePackages(shell["disabled"] ?? "")
        let meta = Dictionary(helper.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        let sizes = Dictionary((storage?.apps ?? []).map { ($0.package, $0) }, uniquingKeysWith: { a, _ in a })
        return index.packages.values.map { p in
            let m = meta[p.name], s = sizes[p.name]
            return AppEntry(name: p.name, label: p.label, uid: p.uid, versionCode: p.versionCode ?? m?.versionCode,
                            versionName: m?.versionName, isSystem: m?.isSystem ?? p.isSystem,
                            enabled: m.map { $0.enabled && !disabled.contains(p.name) } ?? !disabled.contains(p.name),
                            installer: installers[p.name] ?? m?.installer, firstInstall: m?.firstInstall, lastUpdate: m?.lastUpdate,
                            targetSdk: m?.targetSdk, appSize: s?.app, dataSize: s?.data, cacheSize: s?.cache)
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// The apps a filter and a search show; search matches package or label.
    public static func filter(_ apps: [AppEntry], _ filter: AppFilter, query: String) -> [AppEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return apps.filter { a in
            let kind: Bool = switch filter {
            case .all: true
            case .user: !a.isSystem
            case .system: a.isSystem
            case .disabled: !a.enabled
            case .sideloaded: a.source == "Sideloaded"
            }
            return kind && (q.isEmpty || a.name.lowercased().contains(q) || (a.label?.lowercased().contains(q) ?? false))
        }
    }

    /// Which icons to fetch, in helper runs of `batch`: only apps whose icon for this
    /// version is not cached, user apps first so the list fills where it matters.
    public static func iconBatches(_ apps: [AppEntry], cached: Set<String>, batch: Int = 100) -> [[String]] {
        let missing = apps.filter { !cached.contains($0.iconKey) }
            .sorted { a, b in a.isSystem != b.isSystem ? !a.isSystem : a.name < b.name }
            .map(\.name)
        return stride(from: 0, to: missing.count, by: batch).map { Array(missing[$0..<min($0 + batch, missing.count)]) }
    }
}
