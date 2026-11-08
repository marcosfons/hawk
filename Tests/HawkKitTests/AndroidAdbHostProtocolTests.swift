import Foundation
import HawkKit
import Testing

private func bytes(_ s: String) -> Data { Data(s.utf8) }
private func framed(_ s: String) -> String { String(format: "%04x", s.utf8.count) + s }

@Suite struct AndroidAdbHostProtocolTests {
    @Test func requestsAreLengthPrefixed() throws {
        #expect(try AdbHostProtocol.request("host:version") == bytes("000chost:version"))
        #expect(try AdbHostProtocol.request("host:track-devices-l") == bytes("0014host:track-devices-l"))
    }

    @Test func badRequestsAreRefused() {
        #expect(throws: AdbHostProtocol.ProtocolError.badRequest) { try AdbHostProtocol.request("") }
        #expect(throws: AdbHostProtocol.ProtocolError.badRequest) { try AdbHostProtocol.request("host:x\nhost:kill") }
        #expect(throws: AdbHostProtocol.ProtocolError.badRequest) { try AdbHostProtocol.request(String(repeating: "a", count: 70_000)) }
    }

    @Test func versionReply() {
        #expect(AdbHostProtocol.version(bytes("0029")) == 41)
        #expect(AdbHostProtocol.version(bytes("zz")) == nil)
        #expect(AdbHostProtocol.version(bytes("00290")) == nil)
    }

    @Test func okayThenMessages() throws {
        var d = AdbHostProtocol.Decoder()
        let list = "FAKE0001\tdevice\n"
        let frames = try d.feed(bytes("OKAY" + framed(list) + framed("")))
        #expect(frames == [.okay, .message(bytes(list)), .message(Data())])
    }

    @Test func framesSplitAnywhereAreReassembled() throws {
        let stream = bytes("OKAY" + framed("FAKE0001\tdevice\n") + framed("FAKE0001\toffline\n"))
        for chunk in 1...7 {
            var d = AdbHostProtocol.Decoder()
            var frames: [AdbHostProtocol.Frame] = []
            var i = 0
            while i < stream.count {
                frames += try d.feed(stream.subdata(in: i..<min(i + chunk, stream.count)))
                i += chunk
            }
            #expect(frames == [.okay, .message(bytes("FAKE0001\tdevice\n")), .message(bytes("FAKE0001\toffline\n"))])
        }
    }

    @Test func failCarriesTheMessage() {
        var d = AdbHostProtocol.Decoder()
        #expect(throws: AdbHostProtocol.ProtocolError.failed("unknown host service")) {
            _ = try d.feed(bytes("FAIL" + framed("unknown host service")))
        }
    }

    @Test func incompleteFailWaitsForTheRest() throws {
        var d = AdbHostProtocol.Decoder()
        #expect(try d.feed(bytes("FAIL00")).isEmpty)
        #expect(throws: AdbHostProtocol.ProtocolError.failed("no")) { _ = try d.feed(bytes("02no")) }
    }

    @Test func garbageIsMalformed() {
        var a = AdbHostProtocol.Decoder()
        #expect(throws: AdbHostProtocol.ProtocolError.malformed) { _ = try a.feed(bytes("HTTP/1.1 200 OK\r\n")) }
        var b = AdbHostProtocol.Decoder()
        #expect(throws: AdbHostProtocol.ProtocolError.malformed) { _ = try b.feed(bytes("OKAYzzzzhello")) }
        var c = AdbHostProtocol.Decoder()
        #expect(throws: AdbHostProtocol.ProtocolError.malformed) { _ = try c.feed(Data((0..<64).map { UInt8($0 * 7 % 256) })) }
    }

    @Test func parsesLongDeviceList() {
        let payload = """
        FAKE0001               device usb:1-1 product:fakeprod model:Fake_Phone_9 device:fakedev transport_id:3
        192.0.2.10:5555        offline product:fakeprod model:Fake_Phone_9 device:fakedev transport_id:4
        adb-FAKE0001-AbCdEf._adb-tls-connect._tcp unauthorized transport_id:5
        emulator-5554          device product:sdk_phone64 model:sdk_phone64 device:emu64 transport_id:6

        """
        let lines = AdbDeviceLine.parse(payload)
        #expect(lines.count == 4)
        #expect(lines[0] == AdbDeviceLine(serial: "FAKE0001", state: "device", usb: "usb:1-1", product: "fakeprod",
                                          model: "Fake Phone 9", device: "fakedev", transportID: 3))
        #expect(lines[1].usb == nil && lines[1].state == "offline")
        #expect(lines[2].serial == "adb-FAKE0001-AbCdEf._adb-tls-connect._tcp" && lines[2].state == "unauthorized" && lines[2].transportID == 5)
        #expect(lines[3].transportID == 6)
    }

    @Test func parsesShortListAndOddStates() {
        let lines = AdbDeviceLine.parse("FAKE0001\tdevice\nFAKE0002\tno permissions (missing udev rules?); see [http://example.invalid/x] usb:2-1 transport_id:9\n")
        #expect(lines.map(\.state) == ["device", "no permissions"])
        #expect(lines[1].usb == "usb:2-1" && lines[1].transportID == 9)
    }

    @Test func skipsHeadersAndGarbage() {
        let lines = AdbDeviceLine.parse("List of devices attached\n* daemon started successfully\nonlyonetoken\n\u{1}\u{2} device\n")
        #expect(lines.isEmpty)
    }

    @Test func capsDevicesAndFields() {
        let many = (0..<500).map { "FAKE\($0)\tdevice" }.joined(separator: "\n")
        #expect(AdbDeviceLine.parse(many).count == AdbDeviceLine.maxDevices)
        #expect(AdbDeviceLine.parse(String(repeating: "x", count: 1000) + "\tdevice\n").isEmpty)
        #expect(AdbDeviceLine.parse("FAKE0001\tdevice transport_id:notanumber\n").first?.transportID == nil)
    }
}
