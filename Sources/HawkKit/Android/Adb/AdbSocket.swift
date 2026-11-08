import Foundation
import Network
import Synchronization

/// adb's server, spoken to directly on 127.0.0.1. Nothing here starts a server: a
/// refused connection is reported as `serverUnreachable`, and Hawk decides what then.
public struct AdbSocket: Sendable {
    public let port: UInt16

    public init(port: UInt16 = AdbSocket.defaultPort) {
        self.port = port
    }

    /// adb's own override, `ANDROID_ADB_SERVER_PORT`, which adb children inherit too;
    /// otherwise 5037.
    public static var defaultPort: UInt16 {
        ProcessInfo.processInfo.environment["ANDROID_ADB_SERVER_PORT"].flatMap { UInt16($0) }.flatMap { $0 > 0 ? $0 : nil }
            ?? AdbHostProtocol.port
    }

    /// One `host:version` round trip: the server's protocol version (41).
    public func version(timeout: Duration) async throws -> Int {
        try await withTimeout(timeout) { connection in
            try await connection.open()
            try await connection.send(AdbHostProtocol.request("host:version"))
            var decoder = AdbHostProtocol.Decoder()
            while let data = try await connection.receive() {
                for case .message(let payload) in try Self.feed(&decoder, data) {
                    guard let v = AdbHostProtocol.version(payload) else { throw AdbError.closed }
                    return v
                }
            }
            throw AdbError.closed
        }
    }

    /// Whether anything accepts connections on the port. A hung server does; a free
    /// port does not.
    public func isListening(timeout: Duration = .seconds(1)) async -> Bool {
        do {
            try await withTimeout(timeout) { try await $0.open() }
            return true
        } catch {
            return false
        }
    }

    /// `host:track-devices-l`: the device list now, then again on every change. Idle
    /// between changes: no process, no polling. Ends with `serverUnreachable` when the
    /// server goes away; cancelling the consumer closes the connection.
    public func trackDevices() -> AsyncThrowingStream<[AdbDeviceLine], Error> {
        let (stream, continuation) = AsyncThrowingStream<[AdbDeviceLine], Error>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let connection = HostConnection(port: port)
        let task = Task(priority: .utility) {
            do {
                try await Self.withConnectTimeout(connection, .seconds(3))
                try await connection.send(AdbHostProtocol.request("host:track-devices-l"))
                var decoder = AdbHostProtocol.Decoder()
                while let data = try await connection.receive() {
                    for case .message(let payload) in try Self.feed(&decoder, data) {
                        continuation.yield(AdbDeviceLine.parse(String(decoding: payload, as: UTF8.self)))
                    }
                }
                continuation.finish(throwing: AdbError.serverUnreachable)
            } catch {
                continuation.finish(throwing: error)
            }
            connection.close()
        }
        continuation.onTermination = { _ in
            task.cancel()
            connection.close()
        }
        return stream
    }

    private static func feed(_ decoder: inout AdbHostProtocol.Decoder, _ data: Data) throws -> [AdbHostProtocol.Frame] {
        do {
            return try decoder.feed(data)
        } catch AdbHostProtocol.ProtocolError.failed(let message) {
            throw AdbError.commandFailed(status: -1, stderr: message)
        } catch {
            // Not adb's framing: something else holds the port.
            throw AdbError.portInUse
        }
    }

    private static func withConnectTimeout(_ connection: HostConnection, _ timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { try await connection.open(); return true }
            group.addTask { try await Task.sleep(for: timeout); return false }
            let opened = try await group.next() ?? false
            group.cancelAll()
            if !opened {
                connection.close()
                throw AdbError.timeout
            }
        }
    }

    private func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable (HostConnection) async throws -> T) async throws -> T {
        let connection = HostConnection(port: port)
        defer { connection.close() }
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body(connection) }
            group.addTask { try await Task.sleep(for: timeout); return nil }
            guard let first = try await group.next(), let value = first else {
                // Closing the connection ends the pending receive, so the group can return.
                connection.close()
                group.cancelAll()
                throw AdbError.timeout
            }
            group.cancelAll()
            return value
        }
    }
}

/// One TCP connection to the server, with async open, send and receive. Closing it
/// fails whatever is pending.
private final class HostConnection: Sendable {
    private let connection: NWConnection
    private static let queue = DispatchQueue(label: "com.marcos.Hawk.adb-socket", qos: .utility)

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port) ?? 5037, using: .tcp)
    }

    func open() async throws {
        let resumed = Mutex(false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                @Sendable func finish(_ result: Result<Void, Error>) {
                    guard resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                    c.resume(with: result)
                }
                connection.stateUpdateHandler = { [connection] state in
                    switch state {
                    case .ready: finish(.success(()))
                    // Refused: Network would keep retrying in .waiting; adb's absence is an answer.
                    case .waiting, .failed:
                        connection.cancel()
                        finish(.failure(AdbError.serverUnreachable))
                    case .cancelled: finish(.failure(CancellationError()))
                    default: break
                    }
                }
                connection.start(queue: Self.queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if error != nil { c.resume(throwing: AdbError.serverUnreachable) } else { c.resume() }
            })
        }
    }

    /// The next bytes, or nil at end of stream.
    func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let data, !data.isEmpty { c.resume(returning: data) }
                    else if error != nil { c.resume(throwing: AdbError.serverUnreachable) }
                    else if isComplete { c.resume(returning: nil) }
                    else { c.resume(returning: Data()) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func close() { connection.cancel() }
}
