import HawkKit
import Foundation
import Testing

@Suite struct AdbTests {
    @Test func devicesParse() {
        let out = """
        List of devices attached
        R5CX12345AB            device usb:1-1 product:e3qxxx model:SM_S928B device:e3q transport_id:3
        emulator-5554          device product:sdk_gphone64_arm64 model:sdk_gphone64_arm64 device:emu64a transport_id:1
        192.168.0.10:5555      unauthorized transport_id:4
        * daemon started successfully

        """
        let devices = Adb.parseDevices(out)
        #expect(devices.count == 3)
        #expect(devices[0].model == "SM S928B" && devices[0].isReady && devices[0].connection == "USB")
        #expect(devices[1].isEmulator && devices[1].connection == "Emulator")
        #expect(!devices[2].isReady && devices[2].connection == "Wi-Fi")
    }
}

@Suite struct SecurityTests {
    @Test func unusualLocationsAreNamed() {
        #expect(SecurityChecks.unusualLocation("/tmp/x/run") == "a temporary folder")
        #expect(SecurityChecks.unusualLocation("/Users/Shared/agent") != nil)
        #expect(SecurityChecks.unusualLocation(NSHomeDirectory() + "/Downloads/tool") == "Downloads")
        #expect(SecurityChecks.unusualLocation(NSHomeDirectory() + "/.hidden/agent") != nil)
        // Common developer tool folders are fine.
        #expect(SecurityChecks.unusualLocation(NSHomeDirectory() + "/.local/bin/tool") == nil)
        #expect(SecurityChecks.unusualLocation("/Applications/Some.app/Contents/MacOS/Some") == nil)
    }

    @Test func aStartupItemFromATemporaryFolderIsAWarning() {
        let item = LaunchItem(label: "com.example.updater", plist: "/tmp/test.plist", program: "/bin/sh", scope: "You", modified: nil)
        #expect(SecurityChecks.quick(items: [item], processes: []).isEmpty)
        let bad = LaunchItem(label: "com.example.agent", plist: "/tmp/test.plist", program: "/private/tmp/agent", scope: "You", modified: nil)
        let findings = SecurityChecks.quick(items: [bad], processes: [])
        let serious = findings.filter { $0.severity >= Finding.Severity.notice }
        #expect(!serious.isEmpty)
    }

    @Test func aProcessRunningFromDownloadsIsReported() {
        let p = ProcessStat(pid: 99, name: "helper", path: NSHomeDirectory() + "/Downloads/helper")
        #expect(SecurityChecks.quick(items: [], processes: [p]).first?.kind == "Process")
    }
}
