import Foundation
import HawkKit
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let phone = DeviceID("FAKE0001")
private let usb = AdbDeviceLine(serial: "FAKE0001", state: "device", usb: "usb:1-1", model: "Fake Phone", transportID: 1)
private let wifi = AdbDeviceLine(serial: "adb-FAKE0001-AbCdEf._adb-tls-connect._tcp", state: "device", model: "Fake Phone", transportID: 2)

private func kinds(_ events: [DeviceEvent]) -> [DeviceEvent.Kind] { events.map(\.kind) }

@Suite struct AndroidDeviceRegistryTests {
    @Test func plugUnplugPlugIsOneDevice() {
        var r = DeviceRegistry()
        #expect(kinds(r.apply([usb], now: t0)) == [.connected(.usb)])
        #expect(r.needsIdentity == ["FAKE0001"])
        _ = r.resolve(serial: "FAKE0001", as: phone, now: t0)
        #expect(kinds(r.apply([], now: t0 + 10)) == [.disconnected])
        #expect(r.devices[phone]?.isConnected == false)
        #expect(r.devices[phone]?.lastSeen == t0 + 10)
        #expect(kinds(r.apply([usb], now: t0 + 20)) == [.connected(.usb)])
        #expect(r.devices.count == 1)
        #expect(r.events[phone]?.count == 3)
    }

    @Test func sameListTwiceChangesNothing() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        #expect(r.apply([usb], now: t0 + 1).isEmpty)
    }

    @Test func usbToWifiIsATransportChangeNotADisconnect() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        #expect(kinds(r.apply([usb, wifi], now: t0 + 1)) == [.transportAdded(.wifi)])
        #expect(r.preferredSerial(for: phone) == "FAKE0001")   // USB preferred while both are up
        #expect(kinds(r.apply([wifi], now: t0 + 2)) == [.transportRemoved(.usb)])
        #expect(r.preferredSerial(for: phone) == wifi.serial)  // calls move to Wi-Fi
        #expect(r.devices[phone]?.wirelessPaired == true)
        #expect(kinds(r.apply([wifi, usb], now: t0 + 3)) == [.transportAdded(.usb)])
        #expect(r.preferredSerial(for: phone) == "FAKE0001")
        #expect(r.devices.count == 1)
    }

    @Test func wirelessSerialCarriesTheIdentity() {
        var r = DeviceRegistry()
        _ = r.apply([wifi], now: t0)
        #expect(r.devices.keys.first == phone)
    }

    @Test func unauthorizedThenAuthorized() {
        var r = DeviceRegistry()
        let pending = AdbDeviceLine(serial: "FAKE0001", state: "unauthorized", usb: "usb:1-1", transportID: 1)
        #expect(kinds(r.apply([pending], now: t0)) == [.connected(.usb)])
        #expect(r.devices[phone]?.state == .unauthorized)
        #expect(r.preferredSerial(for: phone) == nil)          // no calls while unauthorized
        #expect(r.needsIdentity.isEmpty)                       // and no identity read either
        #expect(kinds(r.apply([usb], now: t0 + 5)) == [.stateChanged(from: .unauthorized, to: .device)])
        #expect(r.needsIdentity == ["FAKE0001"])
        #expect(r.preferredSerial(for: phone) == "FAKE0001")
    }

    @Test func serverRestartInTheMiddleIsOneEvent() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        #expect(kinds(r.serverWentDown(expectBack: true, now: t0 + 1)) == [.serverRestarted])
        #expect(r.devices[phone]?.isConnected == false)
        // The new server's first list is often empty while USB enumerates.
        #expect(r.apply([], now: t0 + 2).isEmpty)
        #expect(r.apply([usb], now: t0 + 3).isEmpty)
        #expect(r.restartDeadline == nil)
        #expect(r.expireRestart(now: t0 + 60).isEmpty)
        #expect(r.needsIdentity == ["FAKE0001"])               // read again after a restart
    }

    @Test func deviceGoneDuringRestartIsDisconnectedAtTheDeadline() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        _ = r.serverWentDown(expectBack: true, now: t0)
        _ = r.apply([], now: t0 + 1)
        #expect(r.expireRestart(now: t0 + 2).isEmpty)
        #expect(kinds(r.expireRestart(now: t0 + DeviceRegistry.restartGrace)) == [.disconnected])
        // Coming back later is a plain connection.
        #expect(kinds(r.apply([usb], now: t0 + 30)) == [.connected(.usb)])
    }

    @Test func userStopDisconnectsAtOnce() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        #expect(kinds(r.serverWentDown(expectBack: false, now: t0 + 1)) == [.disconnected])
        #expect(r.restartDeadline == nil)
    }

    @Test func wrongGuessIsMergedIntoTheRealDevice() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        _ = r.resolve(serial: "FAKE0001", as: phone, now: t0)
        let tcp = AdbDeviceLine(serial: "192.0.2.10:5555", state: "device", model: "Fake Phone", transportID: 3)
        _ = r.apply([usb, tcp], now: t0 + 1)
        #expect(r.devices.count == 2)                          // ip:port is provisional until read
        #expect(r.needsIdentity == ["192.0.2.10:5555"])
        #expect(kinds(r.resolve(serial: "192.0.2.10:5555", as: phone, now: t0 + 2)) == [.transportAdded(.wifi)])
        #expect(r.devices.count == 1)
        #expect(r.devices[phone]?.transports.count == 2)
        #expect(r.devices[phone]?.lastWirelessAddress == "192.0.2.10:5555")
        #expect(r.events[DeviceID("192.0.2.10:5555")] == nil)
        // The same address later is recognised without a new device.
        _ = r.apply([], now: t0 + 3)
        _ = r.apply([tcp], now: t0 + 4)
        #expect(r.devices.count == 1)
    }

    @Test func emulatorsAndSeveralDevices() {
        var r = DeviceRegistry()
        let emu = AdbDeviceLine(serial: "emulator-5554", state: "device", model: "sdk phone", transportID: 7)
        let other = AdbDeviceLine(serial: "FAKE0002", state: "offline", usb: "usb:1-2", transportID: 8)
        _ = r.apply([usb, emu, other], now: t0)
        #expect(r.devices.count == 3)
        #expect(r.devices[DeviceID("emulator-5554")]?.preferred?.kind == .emulator)
        #expect(!r.needsIdentity.contains("emulator-5554"))
        #expect(r.devices[DeviceID("FAKE0002")]?.state == .offline)
        // One device going away does not touch the others.
        #expect(kinds(r.apply([usb, emu], now: t0 + 1)) == [.disconnected])
        #expect(r.devices[phone]?.isConnected == true)
    }

    @Test func devicesNeverDisappearButCanBeForgotten() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        let refused = r.forget(phone)
        #expect(!refused)                                      // not while connected
        _ = r.apply([], now: t0 + 1)
        #expect(r.devices[phone] != nil)
        let forgotten = r.forget(phone)
        #expect(forgotten)
        #expect(r.devices.isEmpty && r.events.isEmpty)
    }

    @Test func savedDevicesStartDisconnected() {
        var saved = Device(id: phone, nickname: "Test phone", model: "Fake Phone", lastSeen: t0)
        saved.transports = [Transport(serial: "FAKE0001", kind: .usb, state: .device, transportID: 1)]
        var r = DeviceRegistry(devices: [saved])
        #expect(r.devices[phone]?.isConnected == false)
        #expect(kinds(r.apply([usb], now: t0 + 1)) == [.connected(.usb)])
        #expect(r.devices[phone]?.nickname == "Test phone")
    }

    @Test func nicknamesAreTrimmedAndCapped() {
        var r = DeviceRegistry()
        _ = r.apply([usb], now: t0)
        r.setNickname("  Test phone  ", for: phone)
        #expect(r.devices[phone]?.name == "Test phone")
        r.setNickname(String(repeating: "x", count: 500), for: phone)
        #expect(r.devices[phone]?.nickname?.count == 64)
        r.setNickname("   ", for: phone)
        #expect(r.devices[phone]?.nickname == nil)
    }

    @Test func eventsAreCapped() {
        var r = DeviceRegistry()
        for i in 0..<400 {
            _ = r.apply([usb], now: t0 + Double(2 * i))
            _ = r.apply([], now: t0 + Double(2 * i + 1))
        }
        #expect(r.events[phone]?.count == DeviceRegistry.maxEvents)
        #expect(r.events[phone]?.last?.kind == .disconnected)
    }

    @Test func eventSummaries() {
        let e = { (k: DeviceEvent.Kind) in DeviceEvent(date: t0, device: phone, kind: k).summary }
        #expect(e(.transportRemoved(.usb)) == "Unplugged from USB")
        #expect(e(.transportAdded(.wifi)) == "Reconnected over Wi-Fi")
        #expect(e(.transportAdded(.usb)) == "Back on USB")
    }

    @Test func wirelessSerialParsing() {
        #expect(AdbSerial.serialNumber(fromWireless: "adb-FAKE0001-AbCdEf._adb-tls-connect._tcp") == "FAKE0001")
        #expect(AdbSerial.serialNumber(fromWireless: "adb-FAKE-0001-AbCdEf._adb-tls-connect._tcp.") == "FAKE-0001")
        #expect(AdbSerial.serialNumber(fromWireless: "adb--x._adb-tls-connect._tcp") == nil)
        #expect(AdbSerial.serialNumber(fromWireless: "FAKE0001") == nil)
        #expect(AdbSerial.address("192.0.2.10:5555") == "192.0.2.10:5555")
        #expect(AdbSerial.address("[2001:db8::1]:5555") != nil)
        #expect(AdbSerial.address("FAKE0001") == nil)
        #expect(AdbSerial.address("host:99999") == nil)
        #expect(AdbSerial.address(":5555") == nil)
    }
}

@Suite struct AndroidWirelessReconnectTests {
    @Test func everyFiveSecondsForAMinuteThenOnlyWithTheTabOpen() {
        var w = WirelessReconnect()
        w.lost(phone, now: 0)
        var attempts: [Double] = []
        var now = 0.0
        while let at = w.nextWake(now: now, tabOpen: false), at < 3600 {
            now = at
            if !w.due(now: now, tabOpen: false).isEmpty { attempts.append(now) }
        }
        #expect(attempts == stride(from: 5.0, through: 60, by: 5).map { $0 })
        #expect(w.nextWake(now: now, tabOpen: false) == nil)   // tab closed: no timer at all
        // Opening the tab resumes, once a minute.
        #expect(w.due(now: 200, tabOpen: true) == [phone])
        #expect(w.nextWake(now: 200, tabOpen: true) == 260)
    }

    @Test func comingBackStopsTheAttempts() {
        var w = WirelessReconnect()
        w.lost(phone, now: 0)
        w.cancel(phone)
        #expect(w.due(now: 10, tabOpen: true).isEmpty)
        #expect(w.nextWake(now: 10, tabOpen: true) == nil)
    }

    @Test func losingAgainDoesNotRestartTheClock() {
        var w = WirelessReconnect()
        w.lost(phone, now: 0)
        w.lost(phone, now: 3)
        #expect(w.nextWake(now: 3, tabOpen: false) == 5)
    }

    @Test func parsesMdnsServices() {
        let out = """
        List of discovered mdns services
        adb-FAKE0001-AbCdEf\t_adb-tls-connect._tcp\t192.0.2.10:37045
        adb-FAKE0001-AbCdEf\t_adb-tls-pairing._tcp\t192.0.2.10:41234
        garbage line
        adb-FAKE0002-XyZ\t_adb-tls-connect._tcp.\tnot-an-address
        """
        let services = MdnsService.parse(out)
        #expect(services.count == 2)
        #expect(services[0].serialNumber == "FAKE0001")
        #expect(services[0].type == MdnsService.connectType)
        #expect(services[0].address == "192.0.2.10:37045")
        #expect(MdnsService.parse(String(repeating: "x\t_adb\t1.2.3.4:5\n", count: 10_000)).count == 256)
    }
}
