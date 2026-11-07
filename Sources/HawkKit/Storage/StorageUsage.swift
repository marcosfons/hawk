import CoreServices
import Foundation

/// "When was this last used?" for a location, from cheap metadata only (no walks).
public enum StorageUsage {
    /// Files whose change marks real activity in a project.
    static let projectMarkers = ["package.json", "package-lock.json", "pnpm-lock.yaml", "yarn.lock", "pubspec.yaml", "pubspec.lock",
                                 "pyproject.toml", "requirements.txt", "uv.lock", "Podfile.lock", "build.gradle", "build.gradle.kts",
                                 ".git/index", ".git/HEAD"]

    /// Folders that belong to a project rather than being one.
    static let projectScoped: Set<String> = ["node_modules", ".venv", "venv", "env", "build", ".dart_tool", "Pods",
                                             "__pycache__", ".pytest_cache", ".mypy_cache", ".ruff_cache"]

    /// Best guess at the last time this location mattered:
    /// - an app bundle: when it was last opened (Spotlight)
    /// - a per-project folder (node_modules, .venv, build…): the project's last activity
    /// - anything else: the newest modification among the folder and its direct contents.
    public static func lastTouched(_ path: String) -> Date? {
        let url = URL(filePath: path)
        if path.hasSuffix(".app"), let used = spotlightLastUsed(path) { return used }
        if projectScoped.contains(url.lastPathComponent) {
            let project = url.deletingLastPathComponent()
            let dates = ([project] + projectMarkers.map { project.appending(path: $0) }).compactMap(modified)
            if let newest = dates.max() { return newest }
        }
        return newestShallow(url)
    }

    static func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    /// The folder's own mtime and that of up to 200 direct children.
    static func newestShallow(_ url: URL) -> Date? {
        var newest = modified(url)
        if let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for item in items.prefix(200) {
                if let d = modified(item), d > (newest ?? .distantPast) { newest = d }
            }
        }
        return newest
    }

    static func spotlightLastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }
}

/// Whether this process has Full Disk Access. Without it macOS silently hides other
/// apps' data (WhatsApp) and the Trash, and so does every scan this process starts.
public func hasFullDiskAccess() -> Bool {
    let probe = StorageRules.expand("~/Library/Application Support/com.apple.TCC/TCC.db")
    let fd = open(probe, O_RDONLY)
    if fd >= 0 { close(fd); return true }
    return false
}
