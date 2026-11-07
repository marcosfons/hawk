import Foundation

/// What may be deleted, and when. Pure logic: the caller supplies what is running.
///
/// Layers, any of which can refuse:
///  1. Protected locations, hard-coded here whatever the registry says. WhatsApp is
///     the strictest: it is measured, never deleted, not even with confirmation.
///  2. The registry's risk: `never` entries are information only.
///  3. Paths that need admin rights, or are too shallow to be a cache, are refused.
///  4. In-use guards: an app or process that holds the files open blocks the delete
///     (learned in mac-clean-caches: a running app just rewrites its cache).
public enum StorageRules {
    public enum Verdict: Equatable, Sendable {
        case allowed
        /// Allowed, but worth a second look (e.g. a project touched this week).
        case caution(String)
        case blocked(String)

        public var isBlocked: Bool { if case .blocked = self { return true } else { return false } }
    }

    /// Never offered for deletion, by path prefix (after ~ expansion).
    public static let protectedPrefixes: [(prefix: String, reason: String)] = [
        ("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared", "WhatsApp data is measured only, never deleted"),
        ("~/Library/Containers/net.whatsapp.WhatsApp", "WhatsApp data is measured only, never deleted"),
        ("~/Library/Developer/Xcode/Archives", "Archives hold the dSYMs of shipped builds"),
        ("~/Library/Application Support/JetBrains", "JetBrains settings and database connections, not cache"),
        ("~/backups", "Backups are permanent"),
    ]

    public static func expand(_ path: String) -> String {
        path.hasPrefix("~") ? NSHomeDirectory() + path.dropFirst() : path
    }

    public static func protectedReason(_ path: String) -> String? {
        let p = (expand(path) as NSString).standardizingPath
        return protectedPrefixes.first { p == expand($0.prefix) || p.hasPrefix(expand($0.prefix) + "/") }?.reason
    }

    /// Whether `path` (one child of `entry`) may be deleted right now.
    public static func verdict(entry: StorageEntry, path: String, running: RunningState, lastTouched: Date?, now: Date = Date()) -> Verdict {
        if let reason = protectedReason(path) { return .blocked(reason) }
        if entry.risk == .never { return .blocked("Marked never in the registry: \(entry.onDelete ?? "not regenerable")") }
        if entry.category == "personal" { return .blocked("Personal data is never offered for deletion") }
        let p = (expand(path) as NSString).standardizingPath
        let home = NSHomeDirectory()
        guard p.hasPrefix(home + "/") else { return .blocked("Outside your home folder: needs admin rights, run it in Terminal") }
        if p.split(separator: "/").count < 4 { return .blocked("Too close to the top of the disk to delete from here") }
        if let reason = inUse(entryID: entry.id, path: p, running: running) { return .blocked(reason) }
        if let lastTouched, now.timeIntervalSince(lastTouched) < 7 * 86400, projectScoped.contains(entry.id) {
            let days = Int(now.timeIntervalSince(lastTouched) / 86400)
            return .caution("This project was touched \(days == 0 ? "today" : "\(days) day\(days == 1 ? "" : "s") ago"): deleting costs a reinstall mid-task")
        }
        return entry.risk == .care ? .caution("Read the care steps first") : .allowed
    }

    /// Entries whose children live inside projects: recency matters more than size.
    public static let projectScoped: Set<String> = ["node-modules", "python-venvs", "project-build-dirs", "dart-tool-dirs",
                                                     "ios-pods-dirs", "python-bytecode-caches"]

    /// Apps or processes that must not be running while an entry is cleared.
    struct Guard {
        let name: String
        let bundleIDs: [String]
        let processPattern: String?     // matched against full command lines
    }

    static let chrome = Guard(name: "Google Chrome", bundleIDs: ["com.google.Chrome", "org.chromium.Chromium"], processPattern: nil)
    static let xcode = Guard(name: "Xcode", bundleIDs: ["com.apple.dt.Xcode"], processPattern: nil)
    static let studio = Guard(name: "Android Studio", bundleIDs: ["com.google.android.studio"], processPattern: nil)
    static let gradle = Guard(name: "the Gradle daemon (run gradle --stop)", bundleIDs: [], processPattern: "GradleDaemon")
    static let jetbrains = Guard(name: "a JetBrains IDE", bundleIDs: ["com.jetbrains."], processPattern: nil)
    static let vscode = Guard(name: "VS Code", bundleIDs: ["com.microsoft.VSCode"], processPattern: nil)
    static let stremio = Guard(name: "Stremio", bundleIDs: ["com.stremio.", "com.westbridge.stremio"], processPattern: "stremio")
    static let dartServer = Guard(name: "the Dart analysis server (an editor is open)", bundleIDs: [], processPattern: "analysis_server")
    static let simulator = Guard(name: "Simulator", bundleIDs: ["com.apple.iphonesimulator"], processPattern: nil)

    static let guards: [String: [Guard]] = [
        "chrome-cache": [chrome],
        "stremio-cache": [stremio],
        "xcode-derived-data": [xcode], "xcode-device-support": [xcode], "cocoapods-cache": [xcode],
        "ios-simulators": [xcode, simulator],
        "gradle-caches": [studio, gradle], "gradle-daemon-logs": [gradle],
        "android-ndk": [studio, gradle], "android-build-tools": [studio, gradle], "android-sdk-rest": [studio, gradle],
        "android-system-images": [studio], "android-studio-app": [studio],
        "jetbrains-caches": [jetbrains, studio],
        "vscode-data": [vscode],
        "dart-analysis-server": [dartServer],
        "pub-cache": [studio], "flutter-engine-cache": [studio], "flutter-sdk-versions": [studio],
    ]

    static func inUse(entryID: String, path: String, running: RunningState) -> String? {
        for g in guards[entryID] ?? [] {
            if g.bundleIDs.contains(where: { id in running.bundleIDs.contains { $0 == id || (id.hasSuffix(".") && $0.hasPrefix(id)) } })
                || g.processPattern.map({ p in running.commandLines.contains { $0.localizedCaseInsensitiveContains(p) } }) == true {
                return "\(g.name) is running: quit it first, it holds these files open"
            }
        }
        // Spotify is the one app whose cache clears fine while it plays (2026-08-18), but
        // only the pure-cache subfolders; its parent folder holds live databases.
        // (Its registry cleanup command removes only those two, so it is not refused.)
        if entryID == "spotify-cache", !path.isEmpty, running.bundleIDs.contains("com.spotify.client"),
           !(path.hasSuffix("/Data") || path.hasSuffix("/Browser")) {
            return "Spotify is open: only its Data and Browser cache folders can go while it runs"
        }
        // An emulator holds its AVD's disk images open.
        if entryID == "android-avd" {
            let avd = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            if running.commandLines.contains(where: { $0.contains("-avd \(avd)") || $0.contains("@\(avd)") }) {
                return "The \(avd) emulator is running"
            }
        }
        return nil
    }

    /// A reclaim command from the registry that Hawk may run as written: complete (no
    /// <placeholders>), not a comment, and not needing sudo or a terminal.
    public static func runnableReclaim(_ entry: StorageEntry) -> String? {
        guard entry.risk != .never, entry.category != "personal", let cmd = entry.reclaim?.trimmingCharacters(in: .whitespaces),
              !cmd.isEmpty, !cmd.hasPrefix("#"), !cmd.contains("<"), !cmd.contains("sudo ") else { return nil }
        if entry.paths.contains(where: { protectedReason($0) != nil }) { return nil }
        // Drop a trailing "# comment" so what runs is exactly what is shown.
        if let hash = cmd.range(of: "   #") { return String(cmd[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return cmd
    }
}

/// What is running, gathered by the caller (bundle IDs from NSWorkspace, command lines
/// of this user's processes).
public struct RunningState: Sendable {
    public var bundleIDs: Set<String>
    public var commandLines: [String]
    public init(bundleIDs: Set<String>, commandLines: [String]) { self.bundleIDs = bundleIDs; self.commandLines = commandLines }
}

/// Full command line of a process (this user's only; nil otherwise).
public func commandLine(_ pid: Int32) -> String? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
    let argc = buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }          // executable path
    while i < size && buf[i] == 0 { i += 1 }          // padding
    var args: [String] = []
    while args.count < argc && i < size {
        let start = i
        while i < size && buf[i] != 0 { i += 1 }
        args.append(String(decoding: buf[start..<i], as: UTF8.self))
        i += 1
    }
    return args.joined(separator: " ")
}
