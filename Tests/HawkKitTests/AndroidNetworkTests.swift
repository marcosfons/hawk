import Foundation
import HawkKit
import Testing

@Suite struct AndroidNetworkTests {
    @Test func configuration() {
        let c = NetworkConfig.parse([
            "dnsMode": "hostname\n", "dnsHost": "dns.example.net\n", "proxy": ":0\n",
            "addr": """
            1: lo    inet 127.0.0.1/8 scope host lo
            30: wlan0    inet 192.0.2.10/24 brd 192.0.2.255 scope global wlan0
            30: wlan0    inet6 fe80::1/64 scope link
            30: wlan0    inet6 2001:db8::10/64 scope global
            40: tun0    inet 10.8.0.2/24 scope global tun0
            """,
            "route": "192.0.2.0/24 dev wlan0 proto kernel scope link src 192.0.2.10\n",
        ])
        #expect(c.privateDNS == "Provider: dns.example.net" && c.proxy == nil)
        #expect(c.interfaces.map(\.name) == ["wlan0", "tun0"])
        #expect(c.interfaces[0].addresses == ["192.0.2.10/24", "2001:db8::10/64"])
        #expect(c.vpn && c.routes.count == 1)
        #expect(NetworkConfig.parse(["dnsMode": "off", "proxy": "proxy.example.net:3128"]).proxy == "proxy.example.net:3128")
        #expect(NetworkConfig.parse(["dnsMode": "null"]).privateDNS == "Automatic")
    }

    @Test func connections() {
        let text = """
          sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
           0: 0A0200C0:BFE0 046433C6:01BB 01 00000000:00000082 00:00000000 00000000 10260        0 8702063 1
           1: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000  2000        0 1
          sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid
           0: 0000000000000000FFFF00000A0200C0:A8A6 0000000000000000FFFF0000057100CB:01BB 06 00000000:00000000 00:00000000 00000000 10349
           1: B80D0120000000000000000010000000:0050 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000 0
        """
        let c = Connection.parse(text)
        #expect(c.count == 4)
        #expect(c[0].local == "192.0.2.10" && c[0].localPort == 49120 && c[0].remote == "198.51.100.4" && c[0].remotePort == 443)
        #expect(c[0].state == "Established" && c[0].uid == 10260)
        #expect(c[1].state == "Listen" && c[1].localPort == 8080 && c[1].remote == "0.0.0.0")
        #expect(c[2].local == "192.0.2.10" && c[2].remote == "203.0.113.5" && c[2].state == "Time wait")
        #expect(c[3].local == "2001:db8::10".replacingOccurrences(of: "::", with: ":0:0:0:0:0:") && c[3].remote == "::")
        #expect(Connection.parse("garbage\n  0: zz:1 00:0 01 x x x 1").isEmpty)
    }

    @Test func tunnels() {
        let forwards = Tunnel.parse("FAKE0001 tcp:8080 tcp:8080\nOTHER tcp:9000 tcp:9000\nFAKE0001 tcp:9222 localabstract:chrome_devtools_remote\n",
                                    direction: .forward, serial: "FAKE0001")
        #expect(forwards.map(\.local) == ["tcp:8080", "tcp:9222"])
        let reverses = Tunnel.parse("UsbFfs tcp:8081 tcp:8081\n", direction: .reverse, serial: nil)
        #expect(reverses == [Tunnel(direction: .reverse, local: "tcp:8081", remote: "tcp:8081")])
        #expect(reverses[0].addArguments == ["reverse", "tcp:8081", "tcp:8081"])
        #expect(reverses[0].removeArguments == ["reverse", "--remove", "tcp:8081"])
        #expect(Tunnel(direction: .forward, local: "tcp:80; reboot", remote: "tcp:80").addArguments == nil)
        #expect(!Tunnel.isSpec("tcp:123456") && Tunnel.isSpec("jdwp:1234"))
    }

    @Test func savedTunnelsAreRecreated() async {
        let fake = FakeDeviceSession()
        let store = DeviceStore(root: FileManager.default.temporaryDirectory.appending(path: "hawk-tunnels-\(UUID().uuidString)"))
        await SavedTunnels.save([Tunnel(direction: .reverse, local: "tcp:8081", remote: "tcp:8081"),
                                 Tunnel(direction: .forward, local: "tcp:9; x", remote: "tcp:9")], fake.id, store: store)
        let done = await SavedTunnels.restore(on: fake, store: store)
        #expect(done == 1)
        #expect(fake.calls == ["exec reverse tcp:8081 tcp:8081"])
    }
}
