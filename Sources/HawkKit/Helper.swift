import Darwin
import Foundation

/// The root helper (`hawkd`) and the newline-delimited JSON spoken over its Unix socket.
/// The helper is the only process that writes to the SMC; it hands the fans back to
/// macOS when its client disconnects or goes quiet.
public enum Helper {
    public static let label = "com.marcos.hawkd"
    public static let socketPath = "/var/run/com.marcos.hawkd.sock"
    /// Without a message for this long, the helper gives the fans back to macOS.
    public static let watchdogSeconds = 5.0
    /// At this SoC temperature the helper gives the fans back to macOS, whatever was asked.
    public static let hotLimit = 90.0
    /// Longest request the helper accepts.
    public static let maxLine = 4096
    /// Longest answer the client accepts (a process list is tens of kilobytes).
    public static let maxResponse = 8 << 20
}

public enum HelperRequest: Codable, Sendable, Equatable {
    /// For logs: the request without its payload.
    public var kind: String {
        switch self {
        case .hello: "hello"
        case .set: "set"
        case .auto: "auto"
        case .processes: "processes"
        }
    }

    case hello
    case set(rpm: Double)
    case auto
    /// Read-only: counters for every process not owned by `skippingUID`.
    case processes(skippingUID: UInt32)
}

public struct HelperResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var manual: Bool
    public var message: String?
    public var processes: [ProcessCounters]?
    public init(ok: Bool, manual: Bool, message: String? = nil, processes: [ProcessCounters]? = nil) {
        self.ok = ok; self.manual = manual; self.message = message; self.processes = processes
    }
}

extension Helper {
    public static func encodeLine<T: Encodable>(_ value: T) -> Data? {
        guard var d = try? JSONEncoder().encode(value) else { return nil }
        d.append(0x0A)
        return d
    }

    public static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
        }
        return addr
    }
}

/// Blocking client for the helper. Keeps one connection open: the open connection is
/// what tells the helper someone is in charge.
public final class HelperClient {
    public private(set) var state: ControlStatus.Helper = .unavailable("not connected")
    private var fd: Int32 = -1
    private var buffer = Data()
    private var nextAttempt = Date.distantPast

    public init() {}
    deinit { disconnect() }

    public var isConnected: Bool { fd >= 0 }

    /// Connects if needed. Reconnection attempts are spaced out so a missing helper costs nothing.
    @discardableResult
    public func connectIfNeeded() -> Bool {
        if fd >= 0 { return true }
        guard Date() >= nextAttempt else { return false }
        nextAttempt = Date().addingTimeInterval(3)
        guard FileManager.default.fileExists(atPath: Helper.socketPath) else { state = .notInstalled; return false }
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { state = .unavailable("socket: \(String(cString: strerror(errno)))"); return false }
        var addr = Helper.address(Helper.socketPath)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard r == 0 else {
            let reason = errno == EACCES ? "permission denied (the helper only accepts admin users)" : String(cString: strerror(errno))
            close(s); state = .unavailable(reason); return false
        }
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fd = s; buffer = Data(); state = .connected
        return true
    }

    public func send(_ request: HelperRequest) -> HelperResponse? {
        guard connectIfNeeded() else { return nil }
        return Log.helper.timed("helper \(request.kind)", warnAbove: 500) { exchange(request) }
    }

    private func exchange(_ request: HelperRequest) -> HelperResponse? {
        guard let line = Helper.encodeLine(request) else { return nil }
        let written = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
        guard written == line.count else { fail("write failed"); return nil }
        while !buffer.contains(0x0A) {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { fail(n == 0 ? "helper closed the connection" : "no answer from the helper"); return nil }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > Helper.maxResponse { fail("answer too long"); return nil }
        }
        let i = buffer.firstIndex(of: 0x0A)!
        let lineData = buffer[buffer.startIndex..<i]
        buffer.removeSubrange(buffer.startIndex...i)
        guard let response = try? JSONDecoder().decode(HelperResponse.self, from: Data(lineData)) else { fail("unreadable answer"); return nil }
        return response
    }

    public func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
    }

    private func fail(_ reason: String) {
        disconnect()
        state = .unavailable(reason)
        Log.helper.warning("Helper connection: \(reason)")
    }
}
