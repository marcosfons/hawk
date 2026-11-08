import Foundation
import HawkKit
import Synchronization
import Testing

/// An executable standing in for adb: `-s SERIAL shell SCRIPT` runs SCRIPT with sh;
/// `-s SERIAL gone` fails the way adb does when the device went away.
private let fakeAdb: String = {
    let dir = FileManager.default.temporaryDirectory.appending(path: "hawk-fake-adb-\(getpid())")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appending(path: "adb").path
    let script = """
    #!/bin/sh
    [ "$1" = "-s" ] || { echo "adb: no devices/emulators found" >&2; exit 1; }
    shift 2
    case "$1" in
        shell) shift; exec /bin/sh -c "$1" ;;
        gone) echo "adb: device 'FAKE0001' not found" >&2; exit 1 ;;
        *) echo "args: $*" ;;
    esac
    """
    FileManager.default.createFile(atPath: path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o755])
    return path
}()

private let phone = DeviceID("FAKE0001")

private final class Counter: Sendable {
    let value = Mutex(0)
    func add() { value.withLock { $0 += 1 } }
    var count: Int { value.withLock { $0 } }
}

private func session(serial: String? = "FAKE0001", slots: AdbSlots = AdbSlots(), timedOut: Counter = Counter()) -> AdbDeviceSession {
    var adb = AdbProcess(executable: fakeAdb, children: ChildProcesses())
    adb.grace = .milliseconds(200)
    return AdbDeviceSession(id: phone, adb: adb, slots: slots, serial: { serial }, timedOut: { timedOut.add() })
}

@Suite struct AndroidDeviceSessionTests {
    @Test func shellReturnsOutputAndStatus() async throws {
        let r = try await session().shell("echo hi; echo err >&2; exit 4", timeout: .seconds(5))
        #expect(r.stdout == "hi\n")
        #expect(r.stderr == "err\n")
        #expect(r.status == 4)
    }

    @Test func commandSayingUnauthorizedIsNotATransportError() async throws {
        let r = try await session().shell("echo 'Permission denied: unauthorized' >&2; exit 1", timeout: .seconds(5))
        #expect(r.status == 1)
    }

    @Test func adbsOwnFailureIsTyped() async throws {
        await #expect(throws: AdbError.deviceNotFound) {
            _ = try await session().shell("echo 'adb: device offline' >&2; echo 'adb: device '\\''FAKE0001'\\'' not found' >&2; exit 1",
                                          timeout: .seconds(5))
        }
        let out = try await session().exec(["gone"], timeout: .seconds(5))
        #expect(out.error == .deviceNotFound)
    }

    @Test func disconnectedDeviceFailsFast() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: AdbError.deviceNotFound) { _ = try await session(serial: nil).shell("sleep 5", timeout: .seconds(10)) }
        #expect(clock.now - start < .milliseconds(200))
        await #expect(throws: AdbError.deviceNotFound) { _ = try await session(serial: "-bad").exec(["x"], timeout: .seconds(1)) }
    }

    @Test func timeoutIsReportedToTheServer() async throws {
        let counter = Counter()
        await #expect(throws: AdbError.timeout) { _ = try await session(timedOut: counter).shell("sleep 10", timeout: .milliseconds(200)) }
        #expect(counter.count == 1)
    }

    @Test func batchEndToEnd() async throws {
        let result = try await session().shellBatch(["a": "echo one", "b": "printf two", "c": "exit 3"], timeout: .seconds(5))
        #expect(result == ["a": "one\n", "b": "two", "c": ""])
    }

    @Test func batchRefusesBadLabels() async {
        await #expect(throws: AdbError.self) { _ = try await session().shellBatch(["a b": "true"], timeout: .seconds(5)) }
    }

    @Test func pushAndPullCheckTheRemotePath() async {
        let local = URL(filePath: "/tmp/x")
        await #expect(throws: AdbError.self) { try await session().push(local, to: "relative/path", timeout: .seconds(5)) }
        await #expect(throws: AdbError.self) { try await session().pull("/sdcard/../data", to: local, timeout: .seconds(5)) }
    }

    @Test func streamDeliversAndHonoursTheLimit() async throws {
        var text = ""
        for try await chunk in session().stream(["shell", "echo a; echo b"]) { text += String(decoding: chunk, as: UTF8.self) }
        #expect(text == "a\nb\n")
        let slots = AdbSlots(streamsPerDevice: 1)
        let s = session(slots: slots)
        let first = Task { for try await _ in s.stream(["shell", "sleep 5"]) {} }
        try await Task.sleep(for: .milliseconds(200))
        await #expect(throws: AdbError.tooManyStreams) { for try await _ in s.stream(["shell", "true"]) {} }
        first.cancel()
    }

    @Test func atMostThreeCallsPerDevice() async throws {
        let slots = AdbSlots()
        let s = session(slots: slots)
        let clock = ContinuousClock()
        let start = clock.now
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 { group.addTask { _ = try await s.shell("sleep 0.3", timeout: .seconds(5)) } }
            try await group.waitForAll()
        }
        // Six 0.3 s calls, three at a time: two rounds.
        #expect(clock.now - start >= .milliseconds(550))
        #expect(await slots.inUse == 0)
    }
}

@Suite struct AndroidAdbSlotsTests {
    @Test func limitsPerDeviceAndInTotal() async throws {
        let slots = AdbSlots(perDevice: 2, total: 3)
        let a = DeviceID("A"), b = DeviceID("B")
        try await slots.acquire(a)
        try await slots.acquire(a)
        try await slots.acquire(b)
        #expect(await slots.inUse == 3)
        let waiting = Task { try await slots.acquire(b) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await slots.inUse == 3)
        await slots.release(a)
        try await waiting.value
        #expect(await slots.inUse == 3)
    }

    @Test func aBusyDeviceDoesNotBlockAnother() async throws {
        let slots = AdbSlots(perDevice: 1, total: 4)
        let a = DeviceID("A"), b = DeviceID("B")
        try await slots.acquire(a)
        let waitingA = Task { try await slots.acquire(a) }
        try await Task.sleep(for: .milliseconds(50))
        try await slots.acquire(b)          // not stuck behind A's waiter
        #expect(await slots.inUse == 2)
        await slots.release(a)
        try await waitingA.value
    }

    @Test func cancelledWaiterLeavesTheQueue() async throws {
        let slots = AdbSlots(perDevice: 1, total: 1)
        let a = DeviceID("A")
        try await slots.acquire(a)
        let waiter = Task { try await slots.acquire(a) }
        try await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await slots.release(a)
        #expect(await slots.inUse == 0)
        try await slots.acquire(a)
        #expect(await slots.inUse == 1)
    }

    @Test func streamCap() async {
        let slots = AdbSlots(streamsPerDevice: 2)
        let a = DeviceID("A")
        #expect(await slots.openStream(a))
        #expect(await slots.openStream(a))
        #expect(await !slots.openStream(a))
        await slots.closeStream(a)
        #expect(await slots.openStream(a))
    }
}

@Suite struct AndroidFakeDeviceSessionTests {
    @Test func scriptedAnswersAndFailures() async throws {
        let fake = FakeDeviceSession()
        fake.answer(shell: "getprop ro.build.version.sdk", with: "35\n")
        fake.answer(batch: "battery", with: "level: 80\n")
        #expect(try await fake.shell("getprop ro.build.version.sdk", timeout: .seconds(1)).stdout == "35\n")
        #expect(try await fake.shellBatch(["battery": "dumpsys battery", "other": "x"], timeout: .seconds(1)) == ["battery": "level: 80\n", "other": ""])
        fake.fail(with: .deviceOffline)
        await #expect(throws: AdbError.deviceOffline) { _ = try await fake.shell("x", timeout: .seconds(1)) }
        #expect(fake.calls.count == 3)
    }
}
