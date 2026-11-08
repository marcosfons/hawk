import Foundation

/// adb's host protocol on 127.0.0.1:5037, the framing only: a request is four hex
/// digits of length then the payload; the server answers OKAY or FAIL, and services
/// like `host:track-devices-l` then send length-prefixed messages for every change.
/// Talking to the server directly costs no process per update and never starts a
/// server on its own, which an `adb` client call would.
public enum AdbHostProtocol {
    public static let port: UInt16 = 5037
    /// Longest message accepted from the server (the length field allows 64 KiB).
    public static let maxPayload = 0xFFFF

    public enum ProtocolError: Error, Sendable, Equatable {
        /// The server said FAIL, with its message.
        case failed(String)
        /// Bytes that are not adb's framing (another program on the port, or garbage).
        case malformed
        /// A request that cannot be framed (too long, not ASCII).
        case badRequest
    }

    /// "000chost:version" for "host:version".
    public static func request(_ service: String) throws -> Data {
        guard !service.isEmpty, service.utf8.count <= maxPayload, service.allSatisfy({ $0.isASCII && !$0.isNewline }) else {
            throw ProtocolError.badRequest
        }
        return Data((String(format: "%04x", service.utf8.count) + service).utf8)
    }

    /// The answer to `host:version`: four hex digits, "0029" for 41.
    public static func version(_ payload: Data) -> Int? {
        guard payload.count == 4, let s = String(data: payload, encoding: .ascii) else { return nil }
        return Int(s, radix: 16)
    }

    /// One thing read from the server.
    public enum Frame: Sendable, Equatable {
        case okay
        /// A length-prefixed message (a device list, a version).
        case message(Data)
    }

    /// Turns bytes, however the socket splits them, into frames. Expects a status
    /// (OKAY or FAIL) first, then messages.
    public struct Decoder: Sendable {
        private var buffer = Data()
        private var gotStatus = false

        public init() {}

        /// Every complete frame in what has arrived so far. Throws on FAIL or garbage;
        /// the connection is then useless and is closed by the caller.
        public mutating func feed(_ data: Data) throws -> [Frame] {
            buffer.append(data)
            var frames: [Frame] = []
            while true {
                if !gotStatus {
                    guard buffer.count >= 4 else { break }
                    let status = String(decoding: buffer.prefix(4), as: UTF8.self)
                    if status == "OKAY" {
                        buffer.removeFirst(4)
                        gotStatus = true
                        frames.append(.okay)
                        continue
                    }
                    guard status == "FAIL" else { throw ProtocolError.malformed }
                    guard let message = try takeMessage(after: 4) else { break }
                    throw ProtocolError.failed(String(decoding: message.prefix(1024), as: UTF8.self))
                }
                guard let message = try takeMessage(after: 0) else { break }
                frames.append(.message(message))
            }
            return frames
        }

        /// A length-prefixed message starting `offset` bytes in, removed from the buffer
        /// with what precedes it; nil while incomplete.
        private mutating func takeMessage(after offset: Int) throws -> Data? {
            guard buffer.count >= offset + 4 else { return nil }
            let start = buffer.startIndex + offset
            let hex = buffer[start..<start + 4]
            guard hex.allSatisfy({ isHexDigit($0) }), let length = Int(String(decoding: hex, as: UTF8.self), radix: 16) else {
                throw ProtocolError.malformed
            }
            guard buffer.count >= offset + 4 + length else { return nil }
            let body = Data(buffer[(start + 4)..<(start + 4 + length)])
            buffer.removeFirst(offset + 4 + length)
            return body
        }

        private func isHexDigit(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) || (b >= 0x41 && b <= 0x46)
        }
    }
}

/// One line of a device list, as `host:track-devices-l` and `adb devices -l` print it:
/// "SERIAL   device usb:1-1 product:x model:Y device:z transport_id:3".
public struct AdbDeviceLine: Sendable, Equatable {
    public let serial: String
    /// adb's word for it: device, offline, unauthorized, authorizing, connecting,
    /// recovery, sideload, bootloader, rescue, host, "no permissions", unknown.
    public let state: String
    /// "usb:1-1" and the like; nil over TCP.
    public let usb: String?
    public let product: String?
    public let model: String?
    public let device: String?
    public let transportID: Int?

    public init(serial: String, state: String, usb: String? = nil, product: String? = nil, model: String? = nil,
                device: String? = nil, transportID: Int? = nil) {
        self.serial = serial
        self.state = state
        self.usb = usb
        self.product = product
        self.model = model
        self.device = device
        self.transportID = transportID
    }

    /// At most this many devices per message, and fields this long, are accepted.
    public static let maxDevices = 64
    static let maxField = 256

    /// Every well-formed line in one message; malformed lines are skipped.
    public static func parse(_ payload: String) -> [AdbDeviceLine] {
        var out: [AdbDeviceLine] = []
        for raw in payload.prefix(AdbHostProtocol.maxPayload).split(whereSeparator: \.isNewline) {
            guard out.count < maxDevices, let line = parseLine(String(raw)) else { continue }
            out.append(line)
        }
        return out
    }

    static func parseLine(_ line: String) -> AdbDeviceLine? {
        if line.hasPrefix("List of devices") || line.hasPrefix("*") { return nil }
        var tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 2, tokens.allSatisfy({ $0.count <= maxField }) else { return nil }
        let serial = tokens.removeFirst()
        guard serial.allSatisfy({ $0.isASCII && !$0.isWhitespace && $0.asciiValue.map { $0 >= 0x21 } == true }) else { return nil }
        var state = tokens.removeFirst()
        // "no permissions (missing udev rules?); see [url]": the words up to the fields.
        if state == "no", tokens.first?.hasPrefix("permissions") == true {
            state = "no permissions"
            while let t = tokens.first, !t.contains(":") || t.hasPrefix("[") || t.hasPrefix("(") { tokens.removeFirst() }
        }
        var fields: [String: String] = [:]
        for t in tokens {
            guard let colon = t.firstIndex(of: ":") else { continue }
            fields[String(t[..<colon])] = String(t[t.index(after: colon)...])
        }
        return AdbDeviceLine(serial: serial, state: state, usb: fields["usb"].map { "usb:" + $0 },
                             product: fields["product"], model: fields["model"].map { $0.replacingOccurrences(of: "_", with: " ") },
                             device: fields["device"], transportID: fields["transport_id"].flatMap { Int($0) })
    }
}
