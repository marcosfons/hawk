import Foundation
import HawkKit
import Testing

private let phone = DeviceID("FAKE0001")

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "hawk-store-\(UUID().uuidString)", directoryHint: .isDirectory)
}

@Suite struct AndroidDeviceStoreTests {
    @Test func folderIsAHashWithPrivatePermissions() async throws {
        let store = DeviceStore(root: tempRoot())
        let name = DeviceStore.folderName(phone)
        #expect(name.count == 16 && name.allSatisfy(\.isHexDigit))
        #expect(!name.contains("FAKE"))
        #expect(DeviceStore.folderName(phone) == name)
        #expect(DeviceStore.folderName(DeviceID("FAKE0002")) != name)
        let folder = try await store.folder(phone)
        let perms = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(perms == 0o700)
        #expect(folder.lastPathComponent == name)
    }

    @Test func savesAreCoalescedAndAtomic() async throws {
        let store = DeviceStore(root: tempRoot())
        await store.save(Data("one".utf8), as: "snapshot.json", for: phone)
        await store.save(Data("two".utf8), as: "snapshot.json", for: phone)
        // Not on disk yet, but readable.
        let file = try await store.folder(phone).appending(path: "snapshot.json")
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(await store.load("snapshot.json", for: phone) == Data("two".utf8))
        await store.flush()
        #expect(try Data(contentsOf: file) == Data("two".utf8))
    }

    @Test func coalescedWriteHappensOnItsOwn() async throws {
        let store = DeviceStore(root: tempRoot(), coalesce: .milliseconds(200))
        await store.save(Data("x".utf8), as: "device.json", for: phone)
        let file = try await store.folder(phone).appending(path: "device.json")
        try await Task.sleep(for: .milliseconds(600))
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func knownDevicesComeBack() async throws {
        let root = tempRoot()
        let store = DeviceStore(root: root)
        let device = Device(id: phone, nickname: "Test phone", model: "Fake Phone", lastSeen: Date(timeIntervalSince1970: 1_800_000_000))
        await store.save(device, as: "device.json", for: phone)
        await store.flush()
        let loaded = await DeviceStore(root: root).loadAll(Device.self, "device.json")
        #expect(loaded == [device])
    }

    @Test func unsafeNamesAreRefused() async throws {
        let store = DeviceStore(root: tempRoot())
        await store.save(Data("x".utf8), as: "../escape.json", for: phone)
        await store.flush()
        #expect(await store.load("../escape.json", for: phone) == nil)
        await #expect(throws: (any Error).self) { try await store.saveBlob(Data(), name: "a/b.png", for: phone) }
        await #expect(throws: (any Error).self) { try await store.saveBlob(Data(), name: ".hidden", for: phone) }
        try await store.saveBlob(Data("png".utf8), name: "com.example.app-12.png", for: phone)
        #expect(await store.blob(name: "com.example.app-12.png", for: phone) == Data("png".utf8))
    }

    @Test func appendRotatesAndEvictsOldestLogcatFirst() async throws {
        let store = DeviceStore(root: tempRoot(), cap: 2_500_000)
        let mb = Data(repeating: 0x41, count: DeviceStore.logFileSize)
        try await store.append(mb, to: .logcat, for: phone)          // file 1, full
        try await Task.sleep(for: .milliseconds(20))
        try await store.append(Data("x".utf8), to: .logcat, for: phone)   // rotates: file 2
        try await store.saveBlob(Data(repeating: 1, count: 1000), name: "icon.png", for: phone)
        #expect(await store.usage(phone) > DeviceStore.logFileSize)
        let logs = try await store.folder(phone).appending(path: "logcat")
        #expect(try FileManager.default.contentsOfDirectory(atPath: logs.path).count == 2)
        try await Task.sleep(for: .milliseconds(20))
        try await store.append(Data(repeating: 0x42, count: 1_000_000), to: .history, for: phone)
        // Not over 2.5 MB yet; more history crosses it.
        try await Task.sleep(for: .milliseconds(20))
        try await store.append(Data(repeating: 0x43, count: 600_000), to: .history, for: phone)
        #expect(await store.usage(phone) <= 2_500_000)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: logs.path)
        #expect(remaining.count == 1)                                // the old full logcat file went first
        #expect(await store.blob(name: "icon.png", for: phone) != nil)
    }

    @Test func forgetRemovesTheFolder() async throws {
        let store = DeviceStore(root: tempRoot())
        let folder = try await store.folder(phone)
        await store.save(Data("x".utf8), as: "device.json", for: phone)
        await store.remove(phone)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        await store.flush()                                          // nothing queued survives a forget
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

@Suite struct AndroidStoreEvictionTests {
    private func file(_ name: String, _ area: StoreArea, _ size: Int, _ age: Double) -> StoreEviction.File {
        .init(path: name, area: area, size: size, modified: Date(timeIntervalSince1970: 1_800_000_000 + age))
    }

    @Test func underTheCapNothingGoes() {
        #expect(StoreEviction.evictions([file("a", .logcat, 10, 0)], cap: 100).isEmpty)
    }

    @Test func logcatOldestFirstThenHistory() {
        let files = [
            file("snapshot", .keep, 10, 0), file("icon", .blobs, 10, 0),
            file("h-old", .history, 30, 1), file("h-new", .history, 30, 5),
            file("l-new", .logcat, 30, 9), file("l-old", .logcat, 30, 2),
        ]
        #expect(StoreEviction.evictions(files, cap: 100) == ["l-old", "l-new"])
        #expect(StoreEviction.evictions(files, cap: 50) == ["l-old", "l-new", "h-old"])
    }

    @Test func keptFilesAreNeverEvictedEvenOverTheCap() {
        let files = [file("snapshot", .keep, 500, 0), file("icon", .blobs, 500, 0), file("l", .logcat, 10, 0)]
        #expect(StoreEviction.evictions(files, cap: 100) == ["l"])
    }
}

@Suite struct AndroidRulesTests {
    private let facts = DeviceFacts(deviceOwner: "com.example.mdm", profileOwners: ["com.example.work"], launcher: "com.example.home")

    private func allowed(_ a: AndroidAction) -> Bool { AndroidRules.verdict(a, facts: facts).isAllowed }

    @Test func ordinaryAppsAreAllowed() {
        #expect(allowed(.forceStop(package: "com.example.game")))
        #expect(allowed(.clearData(package: "com.example.game")))
        #expect(allowed(.uninstall(package: "com.example.game")))
    }

    @Test func systemPackagesAreProtected() {
        for p in ["com.android.settings", "com.android.systemui", "com.android.phone", "com.google.android.packageinstaller", "android"] {
            #expect(!allowed(.uninstall(package: p)))
            #expect(!allowed(.forceStop(package: p)))
        }
    }

    @Test func launcherAndOwnersAreProtected() {
        #expect(!allowed(.disable(package: "com.example.home")))
        #expect(!allowed(.uninstall(package: "com.example.mdm")))
        #expect(!allowed(.clearData(package: "com.example.work")))
    }

    @Test func whatsappDataIsNeverDeleted() {
        #expect(!allowed(.clearData(package: "com.whatsapp")))
        #expect(!allowed(.clearCache(package: "com.whatsapp.w4b")))
        #expect(!allowed(.uninstall(package: "com.whatsapp")))
        #expect(allowed(.forceStop(package: "com.whatsapp")))
        for path in ["/sdcard/WhatsApp", "/sdcard/WhatsApp/Media/x.jpg", "//sdcard//WhatsApp/", "/sdcard/./WhatsApp/Databases",
                     "/storage/emulated/0/Android/media/com.whatsapp/WhatsApp", "/sdcard/Android/media"] {
            #expect(!allowed(.deletePath(path)), "\(path)")
        }
    }

    @Test func systemFoldersAreProtected() {
        for path in ["/", "/sdcard", "/sdcard/", "/data", "/system", "/storage/emulated/0", "/sdcard/DCIM"] {
            #expect(!allowed(.deletePath(path)), "\(path)")
        }
        #expect(allowed(.deletePath("/sdcard/Download/old.apk")))
        #expect(allowed(.deletePath("/sdcard/DCIM/.thumbnails")))
    }

    @Test func invalidInputIsBlocked() {
        #expect(!allowed(.uninstall(package: "com.example.app; reboot")))
        #expect(!allowed(.deletePath("relative")))
        #expect(!allowed(.deletePath("/sdcard/../data")))
    }
}

@Suite struct AndroidActionLogTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func rowsAreOneLineAndCannotBreakTheTable() {
        let row = ActionLog.row(date: date, device: "Test | phone\nx", action: .forceStop(package: "com.example.app"), result: .failed("a|b"))
        #expect(row.hasPrefix("| 2027-01-15 "))
        #expect(row.contains("| Test / phone x | Force stop | com.example.app | failed: a/b |"))
        #expect(row.filter { $0 == "\n" }.count == 1)
    }

    @Test func appendStartsTheTableOnce() async throws {
        let store = DeviceStore(root: FileManager.default.temporaryDirectory.appending(path: "hawk-actions-\(UUID().uuidString)"))
        try await ActionLog.append(date: date, device: "Test phone", action: .clearCache(package: "com.example.app"), result: .done, id: phone, store: store)
        try await ActionLog.append(date: date, device: "Test phone", action: .uninstall(package: "com.android.settings"),
                                   result: .blocked("system"), id: phone, store: store)
        let text = try String(contentsOf: try await store.folder(phone).appending(path: ActionLog.fileName), encoding: .utf8)
        #expect(text.components(separatedBy: "| Time |").count == 2)
        #expect(text.split(separator: "\n").count == 4)
        #expect(text.contains("blocked: system"))
    }
}
