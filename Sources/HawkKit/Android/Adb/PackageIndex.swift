import Foundation

/// One installed package, as `pm list packages -U --show-versioncode` says.
public struct PackageInfo: Sendable, Equatable, Codable {
    public let name: String
    /// The app's UID for user 0; apps sharing a UID share it.
    public var uid: Int?
    public var versionCode: Int64?
    public var isSystem: Bool
    /// Filled by plan B (the on-device helper); nil until then.
    public var label: String?

    public init(name: String, uid: Int?, versionCode: Int64?, isSystem: Bool, label: String? = nil) {
        self.name = name
        self.uid = uid
        self.versionCode = versionCode
        self.isSystem = isSystem
        self.label = label
    }
}

/// The small map every plan needs (logcat's app column, usage, crashes): package
/// name, UID, user or system, version code. One `adb shell` call with two `pm` runs,
/// on connect and when a plan notices a package change.
public struct PackageIndex: Sendable, Equatable, Codable {
    public private(set) var packages: [String: PackageInfo] = [:]
    public private(set) var date: Date

    public init(packages: [PackageInfo] = [], date: Date = .now) {
        self.date = date
        for p in packages { self.packages[p.name] = p }
    }

    /// `--user 0`: without it, a profile the shell may not read (a secure folder)
    /// makes `pm` fail after printing part of the list.
    public static let parts: [String: String] = [
        "all": "pm list packages -U --show-versioncode --user 0",
        "user": "pm list packages --user 0 -3",
    ]

    public static let maxPackages = 5000

    public static func parse(_ parts: [String: String], date: Date = .now) -> PackageIndex {
        let userApps = Set(lines(parts["user"] ?? "").compactMap { fields($0)["package"] })
        var out: [PackageInfo] = []
        for line in lines(parts["all"] ?? "") {
            let f = fields(line)
            guard let name = f["package"], ShellQuote.isPackageName(name) || name == "android" else { continue }
            // "uid:10123" or, for several users or a shared UID, "uid:10123,1010123".
            let uid = f["uid"].flatMap { Int($0.split(separator: ",").first ?? "") }
            out.append(PackageInfo(name: name, uid: uid, versionCode: f["versionCode"].flatMap { Int64($0) },
                                   isSystem: !userApps.contains(name)))
            if out.count >= maxPackages { break }
        }
        return PackageIndex(packages: out, date: date)
    }

    /// Packages running under a UID (several when they share one), sorted.
    public func packages(uid: Int) -> [String] {
        packages.values.filter { $0.uid == uid }.map(\.name).sorted()
    }

    public subscript(_ name: String) -> PackageInfo? { packages[name] }

    public mutating func setLabel(_ label: String?, for name: String) {
        packages[name]?.label = label.map { String($0.prefix(128)) }
    }

    private static func lines(_ text: String) -> [Substring] {
        Array(text.prefix(1 << 20).split(whereSeparator: \.isNewline).prefix(maxPackages * 2))
    }

    /// "package:com.example.app versionCode:12 uid:10123" -> its key:value fields.
    private static func fields(_ line: Substring) -> [String: String] {
        var out: [String: String] = [:]
        for word in line.split(separator: " ") {
            guard let colon = word.firstIndex(of: ":"), word.count <= 300 else { continue }
            out[String(word[..<colon])] = String(word[word.index(after: colon)...])
        }
        return out
    }
}
