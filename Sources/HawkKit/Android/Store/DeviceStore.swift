import CryptoKit
import Foundation

/// What one device folder holds, and what eviction may take.
public enum StoreArea: String, Sendable, CaseIterable {
    /// The device record, snapshot, app list, events, action log: never evicted.
    case keep
    /// Icons and other small blobs: never evicted.
    case blobs
    /// Captured logcat: evicted first, oldest file first.
    case logcat
    /// Long-term history (usage, battery health): evicted second, oldest first.
    case history

    var folder: String? {
        switch self {
        case .keep: nil
        case .blobs: "blobs"
        case .logcat: "logcat"
        case .history: "history"
        }
    }
}

/// Which files to delete to get a device folder under its cap. Pure.
public enum StoreEviction {
    public struct File: Sendable, Equatable {
        public let path: String
        public let area: StoreArea
        public let size: Int
        public let modified: Date
        public init(path: String, area: StoreArea, size: Int, modified: Date) {
            self.path = path
            self.area = area
            self.size = size
            self.modified = modified
        }
    }

    /// Logcat oldest first, then history oldest first, until the total fits; never
    /// anything else, even if the folder stays over the cap.
    public static func evictions(_ files: [File], cap: Int) -> [String] {
        var total = files.reduce(0) { $0 + $1.size }
        guard total > cap else { return [] }
        var out: [String] = []
        for area in [StoreArea.logcat, .history] {
            for f in files.filter({ $0.area == area }).sorted(by: { $0.modified < $1.modified }) {
                guard total > cap else { return out }
                out.append(f.path)
                total -= f.size
            }
        }
        return out
    }
}

/// Hawk's files for Android devices: one folder per device under
/// `~/Library/Application Support/Hawk/Android/`, named by a hash of the serial number
/// (no serials in paths or logs), created 0700, capped (50 MB by default). Writes run
/// on this actor, never the main one; snapshots are coalesced to one write every few
/// seconds and replaced atomically.
public actor DeviceStore {
    public static let defaultCap = 50 << 20
    /// A log file is closed and a new one started past this size.
    public static let logFileSize = 1 << 20
    /// How long a save waits for more saves before writing.
    public let coalesce: Duration

    public let root: URL
    public var cap: Int

    private let files = FileManager.default
    private var pending: [DeviceID: [String: Data]] = [:]
    private var flushTask: Task<Void, Never>?

    public init(root: URL = DeviceStore.defaultRoot, cap: Int = DeviceStore.defaultCap, coalesce: Duration = .seconds(3)) {
        self.root = root
        self.cap = cap
        self.coalesce = coalesce
    }

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Hawk/Android", directoryHint: .isDirectory)
    }

    /// The folder's name for a device: 16 hex digits of SHA-256 of its serial number.
    public nonisolated static func folderName(_ id: DeviceID) -> String {
        SHA256.hash(data: Data(id.rawValue.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    public func folder(_ id: DeviceID) throws -> URL {
        let url = root.appending(path: Self.folderName(id), directoryHint: .isDirectory)
        if !files.fileExists(atPath: url.path) {
            try files.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return url
    }

    // MARK: - Small JSON files, never evicted

    /// Queues a file in the device folder (`device.json`, `snapshot.json`, `apps.json`);
    /// the latest version is written within `coalesce`, atomically.
    public func save(_ data: Data, as name: String, for id: DeviceID) {
        guard Self.isPlainName(name) else { return Log.app.error("Refused to save an Android store file with an unsafe name") }
        pending[id, default: [:]][name] = data
        guard flushTask == nil else { return }
        let wait = coalesce
        flushTask = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: wait, tolerance: wait / 3)
            await self?.flush()
        }
    }

    public func save<T: Encodable>(_ value: T, as name: String, for id: DeviceID) {
        do { save(try JSONEncoder().encode(value), as: name, for: id) } catch {
            Log.app.error("Could not encode \(name) for an Android device: \(error.localizedDescription)")
        }
    }

    /// Writes everything queued now (also called when Hawk quits).
    public func flush() {
        flushTask?.cancel()
        flushTask = nil
        let work = pending
        pending = [:]
        for (id, named) in work {
            for (name, data) in named {
                do { try data.write(to: try folder(id).appending(path: name), options: .atomic) } catch {
                    Log.app.error("Could not write \(name) for an Android device: \(error.localizedDescription)")
                }
            }
        }
    }

    public func load(_ name: String, for id: DeviceID) -> Data? {
        if let queued = pending[id]?[name] { return queued }
        guard Self.isPlainName(name) else { return nil }
        return try? Data(contentsOf: root.appending(path: Self.folderName(id)).appending(path: name))
    }

    public func load<T: Decodable>(_ type: T.Type, _ name: String, for id: DeviceID) -> T? {
        guard let data = load(name, for: id) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) } catch {
            Log.app.warning("Ignoring an unreadable \(name) for an Android device: \(error.localizedDescription)")
            return nil
        }
    }

    /// Every device folder's `name`, decoded (the known devices at launch).
    public func loadAll<T: Decodable>(_ type: T.Type, _ name: String) -> [T] {
        guard let folders = try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: name)) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }

    // MARK: - Logs and blobs

    /// Appends to the area's current file (a new one past `logFileSize`), then evicts
    /// if the folder went over its cap.
    public func append(_ data: Data, to area: StoreArea, for id: DeviceID) throws {
        guard area == .logcat || area == .history, let sub = area.folder else { return }
        let dir = try folder(id).appending(path: sub, directoryHint: .isDirectory)
        try files.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let current = (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "log" }.max { $0.lastPathComponent < $1.lastPathComponent }
        var target = current
        if let c = current, (try? c.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 >= Self.logFileSize { target = nil }
        let url = target ?? dir.appending(path: String(format: "%015.3f.log", Date().timeIntervalSince1970))
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
        evict(id)
    }

    /// A small file Hawk keeps whole (an icon); `name` must be a plain file name.
    public func saveBlob(_ data: Data, name: String, for id: DeviceID) throws {
        guard Self.isPlainName(name), let sub = StoreArea.blobs.folder else { throw CocoaError(.fileWriteInvalidFileName) }
        let dir = try folder(id).appending(path: sub, directoryHint: .isDirectory)
        try files.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: dir.appending(path: name), options: .atomic)
    }

    public func blob(name: String, for id: DeviceID) -> Data? {
        guard Self.isPlainName(name), let sub = StoreArea.blobs.folder else { return nil }
        return try? Data(contentsOf: root.appending(path: Self.folderName(id)).appending(path: sub).appending(path: name))
    }

    // MARK: - Size

    /// Bytes the device's folder uses on disk.
    public func usage(_ id: DeviceID) -> Int {
        listing(id).reduce(0) { $0 + $1.size }
    }

    /// Deletes logcat, then history, oldest first, until the folder fits `cap`.
    @discardableResult
    public func evict(_ id: DeviceID) -> [String] {
        let victims = StoreEviction.evictions(listing(id), cap: cap)
        for path in victims {
            do { try files.removeItem(atPath: path) } catch {
                Log.app.warning("Could not evict an Android store file: \(error.localizedDescription)")
            }
        }
        if !victims.isEmpty { Log.app.info("Android store: evicted \(victims.count) files to stay under the cap") }
        return victims
    }

    /// Keeps one area under `bytes` (the logcat tail's own ~20 MB), oldest files first.
    public func trim(_ area: StoreArea, to bytes: Int, for id: DeviceID) {
        let files = listing(id).filter { $0.area == area }.sorted { $0.modified < $1.modified }
        var total = files.reduce(0) { $0 + $1.size }
        for f in files where total > bytes {
            do { try self.files.removeItem(atPath: f.path); total -= f.size } catch {
                Log.app.warning("Could not trim an Android store file: \(error.localizedDescription)")
            }
        }
    }

    /// "Forget": the device's folder and everything in it.
    public func remove(_ id: DeviceID) {
        pending[id] = nil
        let url = root.appending(path: Self.folderName(id))
        do { if files.fileExists(atPath: url.path) { try files.removeItem(at: url) } } catch {
            Log.app.error("Could not remove a forgotten Android device's folder: \(error.localizedDescription)")
        }
    }

    private func listing(_ id: DeviceID) -> [StoreEviction.File] {
        let base = root.appending(path: Self.folderName(id))
        guard let walker = files.enumerator(at: base, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return [] }
        var out: [StoreEviction.File] = []
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            // By the folder a file sits in, right under the device's: the enumerator may
            // report the root through a resolved symlink (/private/var), so no path maths.
            let parent = url.deletingLastPathComponent()
            let inDeviceSubfolder = parent.deletingLastPathComponent().lastPathComponent == base.lastPathComponent
            let area = inDeviceSubfolder ? StoreArea.allCases.first { $0.folder == parent.lastPathComponent } ?? .keep : .keep
            out.append(.init(path: url.path, area: area, size: v.fileSize ?? 0, modified: v.contentModificationDate ?? .distantPast))
        }
        return out
    }

    /// A single file name: no separators, no "..", nothing hidden, short.
    static func isPlainName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 128 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\0")
    }
}
