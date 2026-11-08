import HawkKit
import Foundation
import Testing

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
