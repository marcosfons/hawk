import Foundation

/// One iOS simulator device, from `xcrun simctl list devices -j`.
public struct SimulatorDevice: Sendable, Identifiable {
    public let udid: String
    public let name: String
    public let runtime: String          // "iOS 18.6"
    public let booted: Bool
    public let bytes: Int64?
    public let lastUsed: Date?
    public let available: Bool
    public var id: String { udid }
}

public enum Xcode {
    public static func simulators() -> [SimulatorDevice] {
        guard let r = runCommand("/usr/bin/xcrun", ["simctl", "list", "devices", "-j"], timeout: 20), r.status == 0,
              let json = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return [] }
        return devices.flatMap { runtimeKey, list in
            list.map { d in
                SimulatorDevice(udid: d["udid"] as? String ?? "?", name: d["name"] as? String ?? "?",
                                runtime: runtimeName(runtimeKey), booted: d["state"] as? String == "Booted",
                                bytes: (d["dataPathSize"] as? NSNumber)?.int64Value,
                                lastUsed: (d["lastUsedAt"] as? String).flatMap(StorageScan.parseDate),
                                available: d["isAvailable"] as? Bool ?? true)
            }
        }
        .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    /// "com.apple.CoreSimulator.SimRuntime.iOS-18-6" -> "iOS 18.6"
    public static func runtimeName(_ key: String) -> String {
        let last = key.components(separatedBy: ".").last ?? key
        guard let dash = last.firstIndex(of: "-") else { return last }
        return last[..<dash] + " " + last[last.index(after: dash)...].replacingOccurrences(of: "-", with: ".")
    }

    /// For a DerivedData folder: the project it builds and when Xcode last opened it.
    /// Flutter apps are all "Runner", so the folder above `ios` names them.
    public static func derivedDataInfo(_ folder: String) -> (project: String?, lastOpened: Date?) {
        guard let plist = NSDictionary(contentsOfFile: folder + "/info.plist") else { return (nil, nil) }
        let workspace = plist["WorkspacePath"] as? String
        var project = workspace.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        if let workspace, project == "Runner" {
            let parts = workspace.split(separator: "/")
            if let ios = parts.lastIndex(of: "ios"), ios > 0 { project = String(parts[ios - 1]) }
        }
        return (project, plist["LastAccessedDate"] as? Date)
    }
}

public enum Stremio {
    /// The cache cap set in Stremio (Settings > Player > Cache size), from its server settings.
    public static func cacheCap() -> Int64? {
        let url = URL(filePath: StorageRules.expand("~/Library/Application Support/stremio-server/server-settings.json"))
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (json["cacheSize"] as? NSNumber)?.int64Value
    }
}

extension StorageRules {
    /// Whether an app or process that owns `entry`'s files is running: checked before an
    /// entry-wide cleanup command, like a path deletion.
    public static func entryInUse(_ entry: StorageEntry, running: RunningState) -> String? {
        inUse(entryID: entry.id, path: "", running: running)
    }
}
