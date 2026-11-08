import Foundation
@testable import HawkKit
import Testing

private let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3]).base64EncodedString()

@Suite struct AndroidHelperOutputTests {
    @Test func parsesEveryRecordKind() {
        let text = [
            "A\tcom.example.game\t128\t1.2.3\t0\t1\t1700000000000\t1800000000000\t35\tcom.android.vending",
            "A\tandroid\t35\t15\t1\t1\t0\t0\t35\t",
            "I\tcom.example.game\t128\tFake Game\t\(png)",
            "I\tcom.example.noicon\t3\tNo Icon\t",
            "N\tw\t1800000000000\t10123\tfg\t1000\t200",
            "N\tm\t1800000000000\t-5\tbg\t30\t4",
            "E\ticons\tcom.example.broken: java.lang.Exception",
            "S\tcpu_ms=230\twall_ms=1100\tpss_kb=41000\thwm_kb=90000",
            "D",
        ].joined(separator: "\n")
        let out = HelperOutput.parse(text)
        #expect(out.complete)
        #expect(out.apps.count == 2)
        #expect(out.apps[0].installer == "com.android.vending" && out.apps[0].targetSdk == 35 && !out.apps[0].isSystem)
        #expect(out.apps[0].lastUpdate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(out.apps[1].installer == nil && out.apps[1].firstInstall == nil && out.apps[1].isSystem)
        #expect(out.icons.count == 2 && out.icons[0].label == "Fake Game" && out.icons[0].png != nil && out.icons[1].png == nil)
        #expect(out.net == [
            NetRecord(transport: .wifi, windowStart: Date(timeIntervalSince1970: 1_800_000_000), uid: 10123, foreground: true, rx: 1000, tx: 200),
            NetRecord(transport: .mobile, windowStart: Date(timeIntervalSince1970: 1_800_000_000), uid: -5, foreground: false, rx: 30, tx: 4),
        ])
        #expect(out.errors.count == 1)
        #expect(out.stats["cpu_ms"] == "230" && out.stats["pss_kb"] == "41000")
    }

    @Test func truncatedRunIsIncomplete() {
        let out = HelperOutput.parse("A\tcom.example.game\t128\t1.2\t0\t1\t1\t1\t35\t\nI\tcom.example.game\t128\tFake")
        #expect(!out.complete)
        #expect(out.apps.count == 1 && out.icons.isEmpty)
    }

    @Test func garbageIsDropped() {
        let text = [
            "A\tcom.example.bad;reboot\t1\tx\t0\t1\t1\t1\t1\t",
            "A\tcom.example.short\t1",
            "I\tcom.example.x\tnotanumber\tX\t",
            "I\tcom.example.y\t1\tY\tnot-base64!!",
            "I\tcom.example.z\t1\tZ\t\(Data("not a png".utf8).base64EncodedString())",
            "N\tq\t1\t1\tfg\t1\t1",
            "N\tw\t1800000000000\t10123\tfg\t-1\t1",
            String(repeating: "x", count: 100_000),
            "\u{0}\u{1}\t\t\t",
        ].joined(separator: "\n")
        let out = HelperOutput.parse(text)
        #expect(out.apps.isEmpty && out.net.isEmpty)
        #expect(out.icons.count == 2 && out.icons.allSatisfy { $0.png == nil })
    }
}

@Suite struct AndroidHelperRunnerTests {
    private let dex = Data("fake dex".utf8)

    @Test func scriptChecksTheHashAndQuotesEverything() throws {
        let runner = HelperRunner(dex: dex, session: FakeDeviceSession())
        let script = try runner.script([.apps, .icons(px: 32, packages: ["com.example.a", "com.example.b;reboot", "android"])], timeout: .seconds(30))
        #expect(runner.hash.count == 64)
        #expect(runner.remotePath == "/data/local/tmp/hawk-helper-\(runner.hash.prefix(16)).dex")
        #expect(script.contains("sha256sum '\(runner.remotePath)'"))
        #expect(script.contains("= \(runner.hash) ]"))
        #expect(script.contains("timeout 30 nice -n 10 app_process / hawk.Helper 'apps' -- 'icons' '32' 'com.example.a' 'android'"))
        #expect(!script.contains("reboot"))
    }

    @Test func invalidCommandsAreRefused() {
        let runner = HelperRunner(dex: dex, session: FakeDeviceSession())
        #expect(throws: AdbError.self) { try runner.script([.icons(px: 32, packages: ["bad name"])], timeout: .seconds(5)) }
        #expect(throws: AdbError.self) { try runner.script([.icons(px: 4096, packages: ["com.example.a"])], timeout: .seconds(5)) }
        let now = Date()
        #expect(throws: AdbError.self) { try runner.script([.net(from: now.addingTimeInterval(-1000 * 86400), to: now, step: 3600)], timeout: .seconds(5)) }
        #expect(HelperCommand.net(from: now.addingTimeInterval(-100 * 86400), to: now, step: 86400).arguments?.count == 4)
    }

    @Test func pushesWhenMissingThenRuns() async throws {
        let fake = FakeDeviceSession()
        let runner = HelperRunner(dex: dex, session: fake)
        let script = try runner.script([.apps], timeout: .seconds(60))
        fake.queue(shell: script, outputs: [HelperRunner.missing + "\n", "A\tcom.example.a\t1\t1\t0\t1\t1\t1\t35\t\nD\n"])
        let out = try await runner.run([.apps])
        #expect(out.complete && out.apps.count == 1)
        #expect(fake.calls.count == 4)
        #expect(fake.calls[1] == "shell rm -f /data/local/tmp/hawk-helper-*.dex")
        #expect(fake.calls[2].hasPrefix("push hawk-helper-") && fake.calls[2].hasSuffix(runner.remotePath))
    }

    @Test func alreadyThereRunsOnce() async throws {
        let fake = FakeDeviceSession()
        let runner = HelperRunner(dex: dex, session: fake)
        fake.answer(shell: try runner.script([.apps], timeout: .seconds(60)), with: "D\n")
        _ = try await runner.run([.apps])
        #expect(fake.calls.count == 1)
    }

    @Test func installThatDoesNotStickFails() async throws {
        let fake = FakeDeviceSession()
        let runner = HelperRunner(dex: dex, session: fake)
        fake.answer(shell: try runner.script([.apps], timeout: .seconds(60)), with: HelperRunner.missing)
        await #expect(throws: AdbError.self) { _ = try await runner.run([.apps]) }
    }
}
