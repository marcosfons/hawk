import Foundation

/// A phone's stable identity: its `ro.serialno`, the same over USB and Wi-Fi.
public struct DeviceID: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (a: DeviceID, b: DeviceID) -> Bool { a.rawValue < b.rawValue }
}

/// adb's state for one transport.
public enum TransportState: Hashable, Sendable, Codable {
    case device, offline, unauthorized, authorizing, connecting, recovery, sideload, bootloader, rescue, noPermissions
    case other(String)

    public init(_ word: String) {
        switch word {
        case "device": self = .device
        case "offline": self = .offline
        case "unauthorized": self = .unauthorized
        case "authorizing": self = .authorizing
        case "connecting": self = .connecting
        case "recovery": self = .recovery
        case "sideload": self = .sideload
        case "bootloader": self = .bootloader
        case "rescue": self = .rescue
        case "no permissions": self = .noPermissions
        default: self = .other(String(word.prefix(32)))
        }
    }

    public var word: String {
        switch self {
        case .device: "device"
        case .offline: "offline"
        case .unauthorized: "unauthorized"
        case .authorizing: "authorizing"
        case .connecting: "connecting"
        case .recovery: "recovery"
        case .sideload: "sideload"
        case .bootloader: "bootloader"
        case .rescue: "rescue"
        case .noPermissions: "no permissions"
        case .other(let w): w
        }
    }

    /// Higher is more useful: a device's state is its best transport's.
    var rank: Int {
        switch self {
        case .device: 9
        case .recovery, .sideload, .rescue, .bootloader: 7
        case .authorizing, .connecting: 5
        case .unauthorized: 4
        case .noPermissions: 3
        case .offline: 2
        case .other: 1
        }
    }
}

public enum TransportKind: String, Hashable, Sendable, Codable, Comparable {
    case usb, wifi, emulator

    /// USB over Wi-Fi over emulator when a device has several.
    var preference: Int { self == .usb ? 0 : self == .wifi ? 1 : 2 }
    public static func < (a: TransportKind, b: TransportKind) -> Bool { a.preference < b.preference }

    static func of(_ line: AdbDeviceLine) -> TransportKind {
        if line.serial.hasPrefix("emulator-") { return .emulator }
        if line.usb != nil { return .usb }
        if AdbSerial.isWireless(line.serial) { return .wifi }
        return .usb
    }
}

/// One way adb reaches a device right now.
public struct Transport: Hashable, Sendable, Codable {
    /// adb's serial for this transport, what `-s` takes.
    public var serial: String
    public var kind: TransportKind
    public var state: TransportState
    public var transportID: Int?

    public init(serial: String, kind: TransportKind, state: TransportState, transportID: Int? = nil) {
        self.serial = serial
        self.kind = kind
        self.state = state
        self.transportID = transportID
    }
}

/// Everything Hawk knows about one device, connected or not.
public struct Device: Hashable, Sendable, Codable, Identifiable {
    public let id: DeviceID
    public var nickname: String?
    public var model: String?
    public var product: String?
    /// Empty while disconnected.
    public var transports: [Transport] = []
    public var lastSeen: Date
    /// Seen over wireless debugging at least once, so Hawk may reconnect it over Wi-Fi.
    public var wirelessPaired = false
    /// The last `ip:port` it was reached at over Wi-Fi.
    public var lastWirelessAddress: String?

    public init(id: DeviceID, nickname: String? = nil, model: String? = nil, product: String? = nil, lastSeen: Date) {
        self.id = id
        self.nickname = nickname
        self.model = model
        self.product = product
        self.lastSeen = lastSeen
    }

    public var isConnected: Bool { !transports.isEmpty }

    /// The transport calls go through: the most useful state, then USB over Wi-Fi.
    public var preferred: Transport? {
        transports.min { a, b in
            a.state.rank != b.state.rank ? a.state.rank > b.state.rank : a.kind < b.kind
        }
    }

    public var state: TransportState? { preferred?.state }
    public var name: String { nickname ?? model ?? id.rawValue }
}

public struct DeviceEvent: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case connected(TransportKind)
        case disconnected
        case transportAdded(TransportKind)
        case transportRemoved(TransportKind)
        case stateChanged(from: TransportState, to: TransportState)
        case serverRestarted
    }
    public let date: Date
    public let device: DeviceID
    public let kind: Kind

    public init(date: Date, device: DeviceID, kind: Kind) {
        self.date = date
        self.device = device
        self.kind = kind
    }

    /// "Unplugged from USB", "Reconnected over Wi-Fi".
    public var summary: String {
        switch kind {
        case .connected(let k): "Connected over \(k.label)"
        case .disconnected: "Disconnected"
        case .transportAdded(let k): k == .wifi ? "Reconnected over Wi-Fi" : "Back on \(k.label)"
        case .transportRemoved(let k): k == .usb ? "Unplugged from USB" : "Lost \(k.label)"
        case .stateChanged(_, let to): "Now \(to.word)"
        case .serverRestarted: "adb server restarted"
        }
    }
}

extension TransportKind {
    public var label: String { self == .usb ? "USB" : self == .wifi ? "Wi-Fi" : "emulator" }
}

/// What adb serials say about themselves.
public enum AdbSerial {
    private static let tlsSuffixes = ["._adb-tls-connect._tcp.", "._adb-tls-connect._tcp"]

    /// `adb-<serialno>-<id>._adb-tls-connect._tcp` carries the device's serial number.
    public static func serialNumber(fromWireless serial: String) -> String? {
        guard serial.hasPrefix("adb-"), let suffix = tlsSuffixes.first(where: { serial.hasSuffix($0) }) else { return nil }
        let middle = serial.dropFirst(4).dropLast(suffix.count)
        guard let dash = middle.lastIndex(of: "-") else { return nil }
        let number = middle[..<dash]
        return number.isEmpty ? nil : String(number)
    }

    public static func isWireless(_ serial: String) -> Bool {
        serialNumber(fromWireless: serial) != nil || address(serial) != nil
    }

    /// "192.0.2.10:5555" -> itself; nil for anything that is not host:port.
    public static func address(_ serial: String) -> String? {
        guard let colon = serial.lastIndex(of: ":"), let port = Int(serial[serial.index(after: colon)...]),
              (1...65535).contains(port), colon > serial.startIndex else { return nil }
        return serial
    }
}
