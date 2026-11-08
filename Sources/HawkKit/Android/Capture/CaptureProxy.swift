import Foundation
import Network
import Synchronization

/// The start of a proxied request: "CONNECT host:443 HTTP/1.1" (HTTPS, tunnelled
/// untouched) or "GET http://host/path HTTP/1.1" (plain HTTP).
public struct ProxyRequestHead: Sendable, Equatable {
    public let method: String
    public let host: String
    public let port: UInt16
    public let path: String?
    public var isTunnel: Bool { method == "CONNECT" }
    /// Bytes of the head, up to and including the blank line.
    public let length: Int

    public static let maxHead = 64 * 1024

    /// nil while the head is incomplete or when it is not a proxy request.
    public static func parse(_ data: Data) -> ProxyRequestHead? {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
        guard let line = head.split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/"), parts[0].allSatisfy(\.isLetter), parts[0].count <= 10 else { return nil }
        let method = String(parts[0]), target = String(parts[1])
        let length = data.distance(from: data.startIndex, to: end.upperBound)
        if method == "CONNECT" {
            let hp = target.split(separator: ":")
            guard hp.count == 2, let port = UInt16(hp[1]), Self.isHost(hp[0]) else { return nil }
            return ProxyRequestHead(method: method, host: String(hp[0]), port: port, path: nil, length: length)
        }
        guard let url = URL(string: target), url.scheme == "http", let host = url.host, Self.isHost(Substring(host)) else { return nil }
        let path = url.path.isEmpty ? "/" : url.path + (url.query.map { "?\($0)" } ?? "")
        return ProxyRequestHead(method: method, host: host, port: UInt16(url.port ?? 80), path: String(path.prefix(500)), length: length)
    }

    /// The head re-addressed to the server ("GET /path HTTP/1.1"), the rest unchanged.
    public static func originForm(_ data: Data, path: String) -> Data {
        var text = String(decoding: data, as: UTF8.self)
        if let lineEnd = text.range(of: "\r\n") {
            let first = text[..<lineEnd.lowerBound].split(separator: " ")
            if first.count == 3 { text.replaceSubrange(..<lineEnd.lowerBound, with: "\(first[0]) \(path) \(first[2])") }
        }
        return Data(text.utf8)
    }

    static func isHost(_ s: Substring) -> Bool { !s.isEmpty && s.count <= 253 && s.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" } }
}

/// One proxied request: host, bytes each way, how long. HTTPS is a tunnel: its
/// content is not seen (decrypting it is an open question).
public struct CapturedRequest: Sendable, Equatable, Identifiable {
    public let id: Int
    public let start: Date
    public let method: String
    public let host: String
    public let port: UInt16
    public let path: String?
    public var status: Int?
    public var up: Int64 = 0
    public var down: Int64 = 0
    public var duration: TimeInterval?
}

/// A small HTTP proxy on 127.0.0.1 (requirements 7.4, level 2): the phone reaches
/// it through `adb reverse`, Hawk records hosts and bytes and relays everything
/// unchanged. It runs only while a capture runs; idle, it does nothing.
public actor CaptureProxy {
    public nonisolated let updates: AsyncStream<[CapturedRequest]>
    private let continuation: AsyncStream<[CapturedRequest]>.Continuation
    private var listener: NWListener?
    private var requests: [CapturedRequest] = []
    private var nextID = 0
    private var dirty = false
    private var flusher: Task<Void, Never>?
    private var open: [Int: Relay] = [:]
    private static let queue = DispatchQueue(label: "com.marcos.Hawk.capture-proxy", qos: .utility)

    public static let maxRequests = 5000

    public init() {
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Starts listening on 127.0.0.1; returns the port.
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in Task { await self?.accept(c) } }
        let ready = Mutex(false)
        l.stateUpdateHandler = { if case .ready = $0 { ready.withLock { $0 = true } } }
        l.start(queue: Self.queue)
        for _ in 0..<100 where !ready.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        guard let port = l.port?.rawValue else { l.cancel(); throw AdbError.commandFailed(status: -1, stderr: "The capture proxy could not listen") }
        listener = l
        flusher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.flush()
            }
        }
        Log.app.info("Capture proxy listening on port \(port)")
        return port
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        for relay in open.values { relay.close() }
        open = [:]
        flusher?.cancel()
        flusher = nil
        flush()
    }

    public func clear() {
        requests = []
        dirty = true
        flush()
    }

    private func accept(_ client: NWConnection) {
        nextID += 1
        let id = nextID
        let relay = Relay(id: id, client: client, queue: Self.queue) { [weak self] event in
            Task { await self?.handle(id, event) }
        }
        open[id] = relay
        relay.start()
    }

    private func handle(_ id: Int, _ event: Relay.Event) {
        switch event {
        case .began(let head):
            requests.append(CapturedRequest(id: id, start: Date(), method: head.method, host: head.host, port: head.port, path: head.path))
            if requests.count > Self.maxRequests { requests.removeFirst(requests.count - Self.maxRequests) }
        case .status(let code):
            if let i = requests.lastIndex(where: { $0.id == id }) { requests[i].status = code }
        case .bytes(let up, let down):
            if let i = requests.lastIndex(where: { $0.id == id }) { requests[i].up += up; requests[i].down += down }
        case .closed:
            open[id] = nil
            if let i = requests.lastIndex(where: { $0.id == id }) { requests[i].duration = Date().timeIntervalSince(requests[i].start) }
        }
        dirty = true
    }

    private func flush() {
        guard dirty else { return }
        dirty = false
        continuation.yield(requests)
    }
}

/// One client connection: reads the request head, connects to the server, then
/// relays both ways counting bytes. Callbacks run on the proxy's queue.
private final class Relay: @unchecked Sendable {
    // Mutable state is touched only on `queue` (every NWConnection callback runs there).
    enum Event: Sendable { case began(ProxyRequestHead), status(Int), bytes(Int64, Int64), closed }

    let id: Int
    let client: NWConnection
    let queue: DispatchQueue
    let report: @Sendable (Event) -> Void
    private var server: NWConnection?
    private var buffer = Data()
    private var closed = false
    private var sawStatus = false

    init(id: Int, client: NWConnection, queue: DispatchQueue, report: @escaping @Sendable (Event) -> Void) {
        self.id = id
        self.client = client
        self.queue = queue
        self.report = report
    }

    func start() {
        client.start(queue: queue)
        readHead()
    }

    func close() {
        queue.async { self.finish() }
    }

    private func readHead() {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [self] data, _, done, error in
            if let data { buffer.append(data) }
            if let head = ProxyRequestHead.parse(buffer) {
                connect(head)
            } else if error != nil || done || buffer.count > ProxyRequestHead.maxHead {
                finish()
            } else {
                readHead()
            }
        }
    }

    private func connect(_ head: ProxyRequestHead) {
        report(.began(head))
        let s = NWConnection(host: NWEndpoint.Host(head.host), port: NWEndpoint.Port(rawValue: head.port) ?? 80, using: .tcp)
        server = s
        s.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                if head.isTunnel {
                    client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    let rest = buffer.dropFirst(head.length)
                    if !rest.isEmpty { s.send(content: Data(rest), completion: .contentProcessed { _ in }) }
                } else {
                    let forwarded = ProxyRequestHead.originForm(buffer, path: head.path ?? "/")
                    report(.bytes(Int64(forwarded.count), 0))
                    s.send(content: forwarded, completion: .contentProcessed { _ in })
                }
                buffer = Data()
                pipe(from: client, to: s, up: true, plain: !head.isTunnel)
                pipe(from: s, to: client, up: false, plain: !head.isTunnel)
            case .failed(let error):
                badGateway(error.localizedDescription)
            case .waiting(let error):
                // Network may retry; give the server 5 s before answering 502.
                queue.asyncAfter(deadline: .now() + 5) { [self] in
                    if s.state != .ready, !closed { badGateway("\(head.host): \(error.localizedDescription)") }
                }
            default:
                break
            }
        }
        s.start(queue: queue)
    }

    private func badGateway(_ why: String) {
        let reason = String(why.filter { $0.isASCII && !$0.isNewline }.prefix(200))
        client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\nX-Hawk-Error: \(reason)\r\nContent-Length: 0\r\n\r\n".utf8),
                    completion: .contentProcessed { [self] _ in finish() })
    }

    private func pipe(from: NWConnection, to: NWConnection, up: Bool, plain: Bool) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, done, error in
            if let data, !data.isEmpty {
                if !up, plain, !sawStatus, data.starts(with: Data("HTTP/".utf8)) {
                    sawStatus = true
                    let line = String(decoding: data.prefix(32), as: UTF8.self).split(separator: " ")
                    if line.count >= 2, let code = Int(line[1]) { report(.status(code)) }
                }
                report(up ? .bytes(Int64(data.count), 0) : .bytes(0, Int64(data.count)))
                to.send(content: data, completion: .contentProcessed { _ in })
            }
            if done || error != nil { finish() } else if !closed { pipe(from: from, to: to, up: up, plain: plain) }
        }
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        client.cancel()
        server?.cancel()
        report(.closed)
    }
}
