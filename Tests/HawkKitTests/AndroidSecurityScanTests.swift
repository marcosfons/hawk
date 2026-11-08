import HawkKit
import Testing

@Suite struct AndroidSecurityScanTests {
    private let parts = [
        "overlay": "com.example.chat\ncom.android.systemui\n",
        "installs": "com.example.store\n",
        "sms": "com.example.spy\ncom.google.android.apps.messaging\n",
        "calllog": "com.example.spy\n",
        "vpn": "com.example.vpn\n",
        "usage": "",
        "a11y": "com.example.spy/com.example.spy.Watcher:com.example.helper/.Service\n",
        "listeners": "com.example.spy/.Listener\n",
        "verifier": "0\n",
        "smsRole": "com.google.android.apps.messaging\n",
        "dialerRole": "com.google.android.dialer\n",
        "admins": "admin=ComponentInfo{com.example.spy/\n",
        "launchers": "com.example.chat/.Main\ncom.example.store/.Main\ncom.example.vpn/.Main\ncom.example.helper/.Main\ncom.example.clean/.Main\n",
        "installers": "package:com.example.chat  installer=com.android.vending\npackage:com.example.spy  installer=null\npackage:com.example.store  installer=com.android.vending\npackage:com.example.vpn  installer=com.android.vending\npackage:com.example.helper  installer=com.example.store\npackage:com.example.clean  installer=com.android.vending\n",
    ]

    @Test func flagsAndOrder() {
        let r = AndroidSecurityScan.parse(parts, userApps: ["com.example.chat", "com.example.spy", "com.example.store", "com.example.vpn", "com.example.helper", "com.example.clean"])
        let spy = r.apps.first
        #expect(spy?.package == "com.example.spy")
        #expect(Set(spy?.flags ?? []) == [.sideloaded, .accessibility, .notificationListener, .deviceAdmin, .sms, .callLog, .hiddenIcon])
        #expect(r.apps.first { $0.package == "com.example.helper" }?.flags == [.sideloaded, .accessibility])
        #expect(r.apps.first { $0.package == "com.example.chat" }?.flags == [.overlay])
        #expect(r.apps.first { $0.package == "com.example.vpn" }?.flags == [.vpn])
        #expect(!r.apps.contains { $0.package == "com.example.clean" })
        #expect(r.device == ["Play Protect app verification is off"])
        // System apps are not scanned.
        #expect(!r.apps.contains { $0.package == "com.android.systemui" })
    }

    @Test func bloatPresentAndProtected() {
        let present = BloatEntry.present(["com.facebook.appmanager", "com.android.settings", "com.example.other"])
        #expect(present.map(\.package) == ["com.facebook.appmanager"])
        #expect(BloatEntry.known.allSatisfy { !AndroidRules.protectedPackages.contains($0.package) })
    }

    @Test func restoreFromTheActionLog() {
        let log = """
        | Time | Device | Action | Target | Result |
        |---|---|---|---|---|
        | 2026-11-08 10:00:00 | Test | Disable | com.facebook.appmanager | done |
        | 2026-11-08 10:01:00 | Test | Uninstall | com.example.bloat | done |
        | 2026-11-08 10:02:00 | Test | Disable | com.example.again | done |
        | 2026-11-08 10:03:00 | Test | Enable | com.example.again | done |
        | 2026-11-08 10:04:00 | Test | Uninstall | com.example.failed | failed: x |
        | 2026-11-08 10:05:00 | Test | Clear cache | com.example.app | done |
        """
        #expect(RemovalRestore.pending(fromActionLog: log) == [.enable(package: "com.facebook.appmanager"), .reinstall(package: "com.example.bloat")])
        #expect(AppActions.command(.reinstall(package: "com.example.bloat"), isSystem: true, cacheOnly: true) == "cmd package install-existing --user 0 'com.example.bloat'")
    }
}
