import Foundation
import HawkKit
import Testing

private let adbIface = USBDevice.Interface(classCode: 0xFF, subclass: 0x42, proto: 1)
private let mtp = USBDevice.Interface(classCode: 6, subclass: 1, proto: 1)
private func phone(_ interfaces: [USBDevice.Interface], speed: Int = 2) -> USBDevice {
    USBDevice(vendorID: 0x04E8, productID: 0x6860, name: "Fake_Android", serial: "FAKE0001", speed: speed, interfaces: interfaces)
}
private func device(_ state: TransportState) -> Device {
    var d = Device(id: DeviceID("FAKE0001"), lastSeen: Date())
    d.transports = [Transport(serial: "FAKE0001", kind: .usb, state: state)]
    return d
}
private func titles(_ f: [ConnectionDoctor.Finding]) -> [String] { f.map(\.title) }

@Suite struct AndroidDoctorTests {
    @Test func nothingOnUSB() {
        let f = ConnectionDoctor.diagnose(usb: [USBDevice(vendorID: 0x05AC, productID: 1, name: "Keyboard", serial: nil, speed: 1, interfaces: [])],
                                          adb: [], installation: nil, serverRunning: true)
        #expect(titles(f) == ["No phone on USB"])
    }

    @Test func fileTransferWithoutDebugging() {
        let f = ConnectionDoctor.diagnose(usb: [phone([mtp])], adb: [], installation: nil, serverRunning: true)
        #expect(titles(f) == ["Fake_Android: USB debugging is off"])
        let charging = ConnectionDoctor.diagnose(usb: [phone([])], adb: [], installation: nil, serverRunning: true)
        #expect(titles(charging) == ["Fake_Android: no adb interface"])
    }

    @Test func statesFromAdb() {
        #expect(ConnectionDoctor.diagnose(usb: [phone([mtp, adbIface])], adb: [device(.unauthorized)], installation: nil, serverRunning: true).first?.severity == .warning)
        #expect(titles(ConnectionDoctor.diagnose(usb: [phone([adbIface])], adb: [device(.offline)], installation: nil, serverRunning: true)) == ["Fake_Android: offline"])
        #expect(titles(ConnectionDoctor.diagnose(usb: [phone([adbIface])], adb: [], installation: nil, serverRunning: true)) == ["Fake_Android: adb does not see it"])
        let ok = ConnectionDoctor.diagnose(usb: [phone([adbIface], speed: 2)], adb: [device(.device)], installation: nil, serverRunning: true)
        #expect(ok.first?.severity == .info && ok.first?.detail.contains("USB 2 (480 Mb/s)") == true)
        #expect(ConnectionDoctor.diagnose(usb: [phone([adbIface], speed: 3)], adb: [device(.device)], installation: nil, serverRunning: true).first?.severity == .ok)
    }

    @Test func serverAndInstallation() {
        let f = ConnectionDoctor.diagnose(usb: [phone([adbIface])], adb: [], installation: AdbInstallation(chosen: nil, others: [], broken: []), serverRunning: false)
        #expect(titles(f).contains("adb is not installed"))
    }

    @Test func pairingPayloadAndService() {
        let p = WirelessPairing(name: "hawk-1234", code: "123456")
        #expect(p.qrPayload == "WIFI:T:ADB;S:hawk-1234;P:123456;;")
        let services = MdnsService.parse("hawk-1234\t_adb-tls-pairing._tcp\t192.0.2.10:41234\nadb-FAKE0001-x\t_adb-tls-connect._tcp\t192.0.2.10:37000\n")
        let found = p.service(in: services)
        #expect(found?.address == "192.0.2.10:41234")
        #expect(found.map(p.pairArguments) == ["pair", "192.0.2.10:41234", "123456"])
        #expect(WirelessPairing().code.count == 6)
    }
}
