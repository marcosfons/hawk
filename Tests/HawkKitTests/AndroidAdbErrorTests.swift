import HawkKit
import Testing

/// stderr lines as adb prints them, with made-up serials, addresses and numbers.
@Suite struct AndroidAdbErrorTests {
    private func classify(_ stderr: String, status: Int32 = 1) -> AdbError? {
        AdbError.classify(status: status, stderr: stderr)
    }

    @Test func successIsNotAnError() {
        #expect(classify("* daemon not running; starting now at tcp:5037\n* daemon started successfully\n", status: 0) == nil)
        #expect(classify("", status: 0) == nil)
    }

    @Test func serverStillStarting() {
        #expect(classify("* daemon not running; starting now at tcp:5037\n") == .serverStarting)
    }

    @Test func serverUnreachable() {
        #expect(classify("* daemon not running; starting now at tcp:5037\nADB server didn't ACK\n* failed to start daemon\nerror: cannot connect to daemon\n") == .serverUnreachable)
        #expect(classify("error: cannot connect to daemon at tcp:5037: Connection refused\n") == .serverUnreachable)
        #expect(classify("adb: could not read OK from ADB Server\n") == .serverUnreachable)
    }

    @Test func refusedPhoneIsNotTheServer() {
        // How `adb connect` reports a phone that is not listening.
        let e = classify("failed to connect to 192.0.2.10:5555: Connection refused\n")
        #expect(e == .commandFailed(status: 1, stderr: "failed to connect to 192.0.2.10:5555: Connection refused"))
    }

    @Test func versionMismatchKeepsBothNumbers() {
        let e = classify("adb server version (40) doesn't match this client (41); killing...\n* daemon started successfully\n")
        #expect(e == .versionMismatch(server: "40", client: "41"))
        #expect(classify("adb server is out of date.  killing...\n") == .versionMismatch(server: nil, client: nil))
    }

    @Test func portInUse() {
        let text = """
        * daemon not running; starting now at tcp:5037
        ADB server didn't ACK
        Full server startup log: /tmp/adb.501.log
        Server had pid: 4242
        --- adb starting (pid 4242) ---
        could not install *smartsocket* listener: Address already in use
        * failed to start daemon
        error: cannot connect to daemon
        """
        #expect(classify(text) == .portInUse)
    }

    @Test func deviceStates() {
        #expect(classify("adb: device 'FAKE0001' not found\n") == .deviceNotFound)
        #expect(classify("error: device 'emulator-5554' not found\n") == .deviceNotFound)
        #expect(classify("adb: no devices/emulators found\n") == .deviceNotFound)
        #expect(classify("adb: device offline\n") == .deviceOffline)
        #expect(classify("adb: device unauthorized.\nThis adb server's $ADB_VENDOR_KEYS is not set\n") == .unauthorized)
        #expect(classify("error: closed\n") == .closed)
        #expect(classify("adb: protocol fault (couldn't read status): Undefined error: 0\n") == .closed)
    }

    @Test func startingThenNoDeviceIsNoDevice() {
        #expect(classify("* daemon not running; starting now at tcp:5037\n* daemon started successfully\nadb: no devices/emulators found\n") == .deviceNotFound)
    }

    @Test func anythingElseIsShownAsIs() {
        #expect(classify("/system/bin/sh: nosuchtool: inaccessible or not found\n", status: 127)
            == .commandFailed(status: 127, stderr: "/system/bin/sh: nosuchtool: inaccessible or not found"))
        #expect(classify("", status: 2) == .commandFailed(status: 2, stderr: ""))
        #expect(AdbError.commandFailed(status: 2, stderr: "").summary == "Exit status 2")
    }

    @Test func hugeOrBinaryStderrIsCapped() {
        let flood = String(repeating: "x", count: 1_000_000)
        guard case .commandFailed(_, let kept) = classify(flood) else {
            Issue.record("expected commandFailed")
            return
        }
        #expect(kept.count == AdbError.maxStderr)
        let binary = String(decoding: (0..<4096).map { UInt8($0 % 256) }, as: UTF8.self)
        #expect(classify(binary) != nil)
    }

    @Test func mismatchNumbersAreBounded() {
        let e = classify("adb server version (\(String(repeating: "9", count: 100))) doesn't match this client (41)\n")
        #expect(e == .versionMismatch(server: nil, client: "41"))
    }
}
