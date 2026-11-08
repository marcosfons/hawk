import Foundation
import HawkKit
import Testing

@Suite struct AndroidReportTests {
    @Test func reportZipsTheKeptFiles() async throws {
        let store = DeviceStore(root: FileManager.default.temporaryDirectory.appending(path: "hawk-report-store-\(UUID().uuidString)"))
        let id = DeviceID("FAKE0001")
        await store.save(Data("{}".utf8), as: "device.json", for: id)
        try await store.append(Data("11-08 10:00:00.000 1 1 1 I t: line\n".utf8), to: .logcat, for: id)
        try await store.saveBlob(Data([1, 2]), name: "icon-x.png", for: id)
        let zip = FileManager.default.temporaryDirectory.appending(path: "report-\(UUID().uuidString).zip")
        _ = try await DeviceReport.write(for: id, name: "Test phone/1", store: store, to: zip)
        let list = try await AdbProcess(executable: "/usr/bin/unzip").run(["-l", zip.path], timeout: .seconds(10)).text
        #expect(list.contains("Test-phone-1-report/device.json") && list.contains("logcat-tail.log"))
        #expect(!list.contains("icon-x.png"))
    }

    @Test func safeNames() {
        #expect(DeviceReport.safe("../evil name") == "---evil-name")
        #expect(DeviceReport.safe("") == "device")
    }
}
