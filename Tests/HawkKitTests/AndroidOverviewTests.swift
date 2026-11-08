import HawkKit
import Testing

/// Made-up device output, shaped like the real thing.
@Suite struct AndroidOverviewTests {
    private let getprop = """
    [ro.product.model]: [Fake Phone 9]
    [ro.product.manufacturer]: [FakeMaker]
    [ro.soc.model]: [FK1234]
    [ro.build.version.release]: [15]
    [ro.build.version.sdk]: [35]
    [ro.build.display.id]: [FAKE.123]
    [ro.build.version.security_patch]: [2026-10-01]
    [ro.product.cpu.abilist]: [arm64-v8a]
    [ro.boot.verifiedbootstate]: [green]
    [ro.boot.flash.locked]: [1]
    [ro.crypto.state]: [encrypted]
    [ro.crypto.type]: [file]
    [persist.sys.empty]: []
    [weird.value]: [has ] inside]
    not a property line
    [unterminated: [x
    """

    @Test func parsesTheSystem() {
        let s = OverviewProbe.parseSystem([
            "props": getprop,
            "kernel": "6.1.99-android14-11\n",
            "selinux": "Enforcing\n",
            "mem": "MemTotal:        7654321 kB\nSwapTotal:       4194300 kB\n",
            "size": "Physical size: 1080x2400\nOverride size: 720x1600\n",
            "density": "Physical density: 420\n",
            "su": "no\n",
        ])
        #expect(s.model == "Fake Phone 9")
        #expect(s.manufacturer == "FakeMaker")
        #expect(s.soc == "FK1234")
        #expect(s.android == "15" && s.sdk == "35")
        #expect(s.securityPatch == "2026-10-01")
        #expect(s.bootloaderLocked == true)
        #expect(s.encryption == "encrypted (file)")
        #expect(s.kernel == "6.1.99-android14-11")
        #expect(s.selinux == "Enforcing")
        #expect(s.ramKB == 7_654_321 && s.swapKB == 4_194_300)
        #expect(s.displaySize == "720x1600")
        #expect(s.density == "420")
        #expect(s.rootIndicators.isEmpty)
        #expect(s.props["persist.sys.empty"] == "")
        #expect(s.props["weird.value"] == "has ] inside")
        #expect(s.props.count == 14)
    }

    @Test func rootIndicators() {
        var s = OverviewProbe.parseSystem(["props": "[ro.boot.flash.locked]: [0]\n[ro.debuggable]: [1]\n", "su": "yes"])
        #expect(s.rootIndicators == ["su present", "bootloader unlocked", "debuggable build"])
        s.props["ro.boot.verifiedbootstate"] = "orange"
        #expect(s.rootIndicators.contains("verified boot orange"))
    }

    @Test func parsesBattery() {
        let b = OverviewProbe.parseBattery("""
        Current Battery Service state:
          AC powered: false
          USB powered: true
          Wireless powered: false
          status: 2
          health: 2
          present: true
          level: 81
          scale: 100
          temperature: 312
          current now: -420
        """)
        #expect(b.level == 81 && b.status == "Charging" && b.source == "USB")
        #expect(b.temperature == 31.2 && b.health == "Good" && b.current == -420)
        let unplugged = OverviewProbe.parseBattery("  AC powered: false\n  USB powered: false\n  status: 3\n  level: 40\n  scale: 50\n")
        #expect(unplugged.source == nil && unplugged.status == "Discharging" && unplugged.level == 80)
    }

    @Test func parsesFocusScreenLockAndDnd() {
        #expect(OverviewProbe.parseFocus("  mCurrentFocus=Window{8b3887b u0 com.example.app/com.example.app.MainActivity}\n")
                == "com.example.app/com.example.app.MainActivity")
        #expect(OverviewProbe.parseFocus("  mCurrentFocus=Window{8b3887b u0 NotificationShade}") == "NotificationShade")
        #expect(OverviewProbe.parseFocus("  mCurrentFocus=null") == nil)
        #expect(OverviewProbe.parseWakefulness("  mWakefulness=Awake\n") == true)
        #expect(OverviewProbe.parseWakefulness("  mWakefulness=Dozing\nFailed to write while dumping service power: Broken pipe") == false)
        #expect(OverviewProbe.parseWakefulness("nothing") == nil)
        #expect(OverviewProbe.parseKeyguard("    KeyguardServiceDelegate\n      showing=true\n      inputRestricted=true\n") == true)
        #expect(OverviewProbe.parseKeyguard("    KeyguardServiceDelegate\n      showing=false\n") == false)
        #expect(OverviewProbe.parseZen("1\n") == "Priority only")
        #expect(OverviewProbe.parseZen("0") == "Off")
        #expect(OverviewProbe.parseZen("null") == nil)
    }

    @Test func eachTickReadsOnlyWhatItMust() {
        #expect(Set(OverviewProbe.rightNow(tick: 0).keys) == ["focus", "battery", "power", "keyguard", "zen"])
        #expect(Set(OverviewProbe.rightNow(tick: 1).keys) == ["focus"])
        #expect(Set(OverviewProbe.rightNow(tick: 2).keys) == ["focus", "battery"])
        // Over 30 ticks (90 s): 30 focus, 15 battery, 3 of the slow reads.
        let reads = (0..<30).flatMap { OverviewProbe.rightNow(tick: $0).keys }
        #expect(reads.filter { $0 == "battery" }.count == 15)
        #expect(reads.filter { $0 == "zen" }.count == 3)
        #expect(OverviewProbe.rightNow(tick: 7).keys.allSatisfy(ShellBatch.isLabel))
    }

    @Test func mergeKeepsWhatThisTickDidNotRead() {
        var now = OverviewProbe.merge(["focus": "  mCurrentFocus=Window{1 u0 com.example.a/.Main}", "battery": "  level: 50\n",
                                       "power": "mWakefulness=Awake", "keyguard": "showing=false", "zen": "0"], into: RightNow())
        now = OverviewProbe.merge(["focus": "  mCurrentFocus=Window{1 u0 com.example.b/.Main}"], into: now)
        #expect(now.foreground == "com.example.b/.Main")
        #expect(now.battery?.level == 50 && now.screenOn == true && now.locked == false && now.doNotDisturb == "Off")
    }

    @Test func garbageNeverCrashes() {
        let junk = String(repeating: "[[[]]]::: \u{0}\n", count: 20_000)
        _ = OverviewProbe.parseSystem(["props": junk, "mem": junk, "size": junk, "density": junk, "kernel": junk])
        _ = OverviewProbe.parseBattery(junk + "level: 99999999999999999999\n")
        _ = OverviewProbe.parseFocus("mCurrentFocus=Window{}")
        #expect(OverviewProbe.parseGetprop(junk).count <= 5000)
        #expect(OverviewProbe.parseBattery("level: 99999999999999999999").level == nil)
    }
}
