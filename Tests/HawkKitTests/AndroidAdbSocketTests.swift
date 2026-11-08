import Foundation
import HawkKit
import Network
import Synchronization
import Testing

/// A stand-in adb server on a random local port. `reply` is sent once the request
/// arrives (nil: accept and say nothing, like a hung server); `closeAfter` closes it.
private final class FakeServer: Sendable {
    private let listener: NWListener
    private final class Connections: Sendable {
        let list = Mutex<[NWConnection]>([])
    }
    private let connections = Connections()
    private static let queue = DispatchQueue(label: "fake-adb")

    init(reply: Data?, closeAfter: Bool) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [connections] c in
            connections.list.withLock { $0.append(c) }
            c.start(queue: Self.queue)
            c.receive(minimumIncompleteLength: 4, maximumLength: 1024) { _, _, _, _ in
                guard let reply else { return }
                c.send(content: reply, completion: .contentProcessed { _ in
                    if closeAfter { c.cancel() }
                })
            }
        }
        let ready = Mutex(false)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.withLock { $0 = true } } }
        listener.start(queue: Self.queue)
        for _ in 0..<100 where !ready.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
    }

    var port: UInt16 { listener.port?.rawValue ?? 0 }

    func stop() {
        listener.cancel()
        connections.list.withLock { $0.forEach { $0.cancel() } }
    }
}

private func framed(_ s: String) -> String { String(format: "%04x", s.utf8.count) + s }

@Suite struct AndroidAdbSocketTests {
    @Test func readsTheVersion() async throws {
        let server = try await FakeServer(reply: Data(("OKAY" + framed("0029")).utf8), closeAfter: true)
        defer { server.stop() }
        #expect(try await AdbSocket(port: server.port).version(timeout: .seconds(2)) == 41)
        #expect(await AdbSocket(port: server.port).isListening())
    }

    @Test func refusedPortIsUnreachableNotAStart() async throws {
        let server = try await FakeServer(reply: nil, closeAfter: false)
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: AdbError.serverUnreachable) { _ = try await AdbSocket(port: port).version(timeout: .seconds(2)) }
        #expect(await !AdbSocket(port: port).isListening())
    }

    @Test func hungServerTimesOut() async throws {
        let server = try await FakeServer(reply: nil, closeAfter: false)
        defer { server.stop() }
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: AdbError.timeout) { _ = try await AdbSocket(port: server.port).version(timeout: .milliseconds(300)) }
        #expect(clock.now - start < .seconds(2))
        // It accepts connections, so it still counts as listening.
        #expect(await AdbSocket(port: server.port).isListening())
    }

    @Test func failIsReported() async throws {
        let server = try await FakeServer(reply: Data(("FAIL" + framed("unknown host service")).utf8), closeAfter: true)
        defer { server.stop() }
        await #expect(throws: AdbError.commandFailed(status: -1, stderr: "unknown host service")) {
            _ = try await AdbSocket(port: server.port).version(timeout: .seconds(2))
        }
    }

    @Test func somethingElseOnThePortIsPortInUse() async throws {
        let server = try await FakeServer(reply: Data("HTTP/1.1 400 Bad Request\r\n\r\n".utf8), closeAfter: true)
        defer { server.stop() }
        await #expect(throws: AdbError.portInUse) { _ = try await AdbSocket(port: server.port).version(timeout: .seconds(2)) }
    }

    @Test func trackDevicesDeliversListsThenEndsWhenTheServerGoes() async throws {
        let payload = "OKAY" + framed("FAKE0001               device usb:1-1 model:Fake_Phone transport_id:1\n")
            + framed("FAKE0001               device usb:1-1 model:Fake_Phone transport_id:1\nemulator-5554          offline transport_id:2\n")
            + framed("")
        let server = try await FakeServer(reply: Data(payload.utf8), closeAfter: true)
        defer { server.stop() }
        var lists: [[AdbDeviceLine]] = []
        await #expect(throws: AdbError.serverUnreachable) {
            for try await list in AdbSocket(port: server.port).trackDevices() { lists.append(list) }
        }
        #expect(lists.map(\.count) == [1, 2, 0])
        #expect(lists[1][1].state == "offline")
    }

    @Test func trackDevicesOnNoServerFailsFast() async throws {
        let server = try await FakeServer(reply: nil, closeAfter: false)
        let port = server.port
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: AdbError.serverUnreachable) {
            for try await _ in AdbSocket(port: port).trackDevices() {}
        }
    }

    @Test func cancellingTheWatchClosesIt() async throws {
        let server = try await FakeServer(reply: Data(("OKAY" + framed("FAKE0001\tdevice\n")).utf8), closeAfter: false)
        defer { server.stop() }
        let port = server.port
        let consumer = Task {
            var n = 0
            for try await _ in AdbSocket(port: port).trackDevices() { n += 1 }
            return n
        }
        try await Task.sleep(for: .milliseconds(300))
        consumer.cancel()
        let clock = ContinuousClock()
        let start = clock.now
        _ = try? await consumer.value
        #expect(clock.now - start < .seconds(1))
    }
}
