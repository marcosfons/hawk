import Foundation
import HawkKit
import Testing

@Suite struct AndroidWifiTests {
    @Test func hotspot() {
        #expect(Tethering.tetheredInterfaces("    wlan1 - TETHERED\n    rndis0 - AVAILABLE\n") == ["wlan1"])
        #expect(Tethering.tetheredInterfaces("    wlan1 - AVAILABLE\n").isEmpty)
    }

    @Test func savedNetworksWithSpaces() {
        let n = SavedWifi.parse("Network Id      SSID                         Security type\n0            Home Network                 wpa2-psk\n3            Cafe                         open\n")
        #expect(n == [SavedWifi(id: 0, ssid: "Home Network", security: "wpa2-psk"), SavedWifi(id: 3, ssid: "Cafe", security: "open")])
    }

    @Test func addNetworkCommand() {
        #expect(SavedWifi.addCommand(ssid: "Home's Net", security: "wpa2", passphrase: "secret123") == "cmd wifi add-network 'Home'\\''s Net' wpa2 'secret123'")
        #expect(SavedWifi.addCommand(ssid: "Cafe", security: "open", passphrase: nil) == "cmd wifi add-network 'Cafe' open")
        #expect(SavedWifi.addCommand(ssid: "Home", security: "wpa2", passphrase: "short") == nil)
        #expect(SavedWifi.addCommand(ssid: "Home", security: "rm -rf", passphrase: "secret123") == nil)
        #expect(SavedWifi.addCommand(ssid: "a\nb", security: "open", passphrase: nil) == nil)
    }

    @Test func macSide() {
        #expect(MacWifi.interface(fromHardwarePorts: "Hardware Port: Ethernet\nDevice: en1\n\nHardware Port: Wi-Fi\nDevice: en0\nEthernet Address: x") == "en0")
        #expect(MacWifi.preferred("Preferred networks on en0:\n\tHome Network\n\tCafe\n") == ["Home Network", "Cafe"])
    }

    @Test func certificateSubjects() {
        let cas = CAStore.parse("        Subject: C=US, O=Example Trust, CN=Example Root CA\n        Subject: C=US, O=Solo\nnoise\n")
        #expect(cas == ["Example Root CA (Example Trust)", "Solo"])
    }

    @Test func dataTotalsFromHistory() {
        var h = UsageHistory()
        let now = Date(timeIntervalSince1970: 1_800_014_400)
        let today = Calendar.current.startOfDay(for: now)
        h.merge([NetRecord(transport: .wifi, windowStart: today, uid: 10100, foreground: true, rx: 100, tx: 0),
                 NetRecord(transport: .mobile, windowStart: today, uid: -5, foreground: true, rx: 30, tx: 0)],
                fetched: h.nextFetch(now: now), now: now)
        let t = DeviceDataTotals.totals(h, days: 1, now: now)
        #expect(t.wifi == 100 && t.mobile == 30 && t.hotspot == 30)
    }
}
