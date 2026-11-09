import Foundation
import HawkKit
import Testing

@Suite struct AndroidHealthTests {
    private let id = DeviceID("FAKE0001")
    private let m = DeviceHealth.marker

    private func output(level: Int, ac: Bool = false, status: Int = 3, totalKB: Int = 100_000_000, freeKB: Int) -> String {
        """
        12345 data_app_crash (text, 100 bytes)
        \(m)
        Current Battery Service state:
          AC powered: \(ac)
          USB powered: false
          status: \(status)
          level: \(level)
          scale: 100
        \(m)
        Filesystem       1K-blocks     Used Available Use% Mounted on
        /dev/block/dm-9  \(totalKB) \(totalKB - freeKB) \(freeKB) 90% /data

        """
    }

    @Test func splitKeepsTheListingAndReadsTheProbe() {
        let (before, reading) = DeviceHealth.split(output(level: 40, freeKB: 30_000_000))
        #expect(before == "12345 data_app_crash (text, 100 bytes)\n")
        #expect(reading?.battery?.level == 40)
        #expect(reading?.storage?.free == Int64(30_000_000) * 1024)
    }

    @Test func noProbeLeavesTheOutputAlone() {
        let text = "12345 data_app_crash (text, 100 bytes)\n"
        let (before, reading) = DeviceHealth.split(text)
        #expect(before == text && reading == nil)
    }

    @Test func garbageAfterTheMarkerGivesNoValues() {
        let (_, reading) = DeviceHealth.split("x\n\(m)\n\u{0}\u{1}level: \n\(m)\nnot df at all\n")
        #expect(reading?.battery == nil && reading?.storage == nil)
        let truncated = DeviceHealth.split("x\n\(m)\nlevel: 5\n")
        #expect(truncated.reading == nil)
    }

    @Test func batteryLowAlertsOnceUntilItCharges() throws {
        var tracker = DeviceHealth.Tracker()
        func read(_ text: String) -> [DeviceHealth.Alert] {
            tracker.evaluate(DeviceHealth.split(text).reading!, device: id, name: "Test phone")
        }
        #expect(read(output(level: 30, freeKB: 50_000_000)).isEmpty)
        let low = read(output(level: 14, freeKB: 50_000_000))
        #expect(low.map(\.issue) == [.batteryLow])
        #expect(low.first?.title == "Test phone battery low")
        #expect(read(output(level: 12, freeKB: 50_000_000)).isEmpty)
        #expect(read(output(level: 20, freeKB: 50_000_000)).isEmpty)   // above the line, below the margin
        #expect(read(output(level: 13, freeKB: 50_000_000)).isEmpty)
        #expect(read(output(level: 13, ac: true, status: 2, freeKB: 50_000_000)).isEmpty)   // charging clears
        #expect(read(output(level: 12, freeKB: 50_000_000)).map(\.issue) == [.batteryLow])
    }

    @Test func chargingAtALowLevelDoesNotAlert() {
        var tracker = DeviceHealth.Tracker()
        let r = DeviceHealth.split(output(level: 5, ac: true, status: 2, freeKB: 50_000_000)).reading!
        #expect(tracker.evaluate(r, device: id, name: "Test phone").isEmpty)
    }

    @Test func storageAlertsBelowTenPercentAndClearsAboveFifteen() {
        var tracker = DeviceHealth.Tracker()
        func read(free: Int) -> [DeviceHealth.Issue] {
            tracker.evaluate(DeviceHealth.split(output(level: 80, freeKB: free)).reading!, device: id, name: "Test phone").map(\.issue)
        }
        #expect(read(free: 11_000_000).isEmpty)
        #expect(read(free: 9_000_000) == [.storageFull])
        #expect(read(free: 12_000_000).isEmpty)
        #expect(read(free: 9_000_000).isEmpty)
        #expect(read(free: 16_000_000).isEmpty)
        #expect(read(free: 9_000_000) == [.storageFull])
    }

    @Test func aForgottenDeviceAlertsAgain() {
        var tracker = DeviceHealth.Tracker()
        let r = DeviceHealth.split(output(level: 10, freeKB: 50_000_000)).reading!
        #expect(tracker.evaluate(r, device: id, name: "Test phone").count == 1)
        #expect(tracker.evaluate(r, device: id, name: "Test phone").isEmpty)
        tracker.forget(id)
        #expect(tracker.evaluate(r, device: id, name: "Test phone").count == 1)
    }

    @Test func devicesAreTrackedApart() {
        var tracker = DeviceHealth.Tracker()
        let r = DeviceHealth.split(output(level: 10, freeKB: 50_000_000)).reading!
        #expect(tracker.evaluate(r, device: id, name: "A").count == 1)
        #expect(tracker.evaluate(r, device: DeviceID("FAKE0002"), name: "B").count == 1)
    }
}
