import Foundation

/// A one-click report of a device (requirements 14.4): everything Hawk keeps for
/// it, zipped where the user chooses. It holds no secrets (Hawk stores none) but
/// may hold app names and log lines, so it is only ever written where the user
/// picks; nothing is sent anywhere.
public enum DeviceReport {
    /// Files of the device folder that go in, when present: records and snapshots,
    /// not icons or the whole log tail.
    public static let files = ["device.json", "snapshot.json", "events.json", "crashes.json", "storage.json", "apps.json",
                               "packages.json", "management.json", "usage.json", ActionLog.fileName]

    /// Copies the files (and the newest logcat tail file) into a fresh folder, then
    /// zips it with ditto. Returns the zip.
    public static func write(for id: DeviceID, name: String, store: DeviceStore, to zip: URL) async throws -> URL {
        let folder = try await store.folder(id)
        let work = FileManager.default.temporaryDirectory.appending(path: "hawk-report-\(UUID().uuidString)")
        let root = work.appending(path: safe(name) + "-report", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        await store.flush()
        for f in files where FileManager.default.fileExists(atPath: folder.appending(path: f).path) {
            try FileManager.default.copyItem(at: folder.appending(path: f), to: root.appending(path: f))
        }
        let logs = folder.appending(path: "logcat")
        if let newest = (try? FileManager.default.contentsOfDirectory(atPath: logs.path))?.filter({ $0.hasSuffix(".log") }).max() {
            try FileManager.default.copyItem(at: logs.appending(path: newest), to: root.appending(path: "logcat-tail.log"))
        }
        let out = try await AdbProcess(executable: "/usr/bin/ditto").run(["-c", "-k", "--keepParent", root.path, zip.path], timeout: .seconds(120))
        guard out.status == 0 else { throw CocoaError(.fileWriteUnknown) }
        return zip
    }

    /// A name with plain characters only, for files.
    public static func safe(_ name: String) -> String {
        let s = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }.prefix(40))
        return s.isEmpty ? "device" : s
    }
}
