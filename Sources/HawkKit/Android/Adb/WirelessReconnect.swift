import Foundation

/// One line of `adb mdns services`: "adb-SERIAL-AbCdEf	_adb-tls-connect._tcp	192.0.2.10:37045".
public struct MdnsService: Hashable, Sendable {
    public let name: String
    public let type: String
    public let address: String

    public static let connectType = "_adb-tls-connect._tcp"

    /// The device's serial number, from the service name.
    public var serialNumber: String? {
        AdbSerial.serialNumber(fromWireless: name + "." + MdnsService.connectType)
    }

    public static func parse(_ output: String) -> [MdnsService] {
        var out: [MdnsService] = []
        for raw in output.prefix(64 * 1024).split(whereSeparator: \.isNewline).prefix(256) {
            let fields = raw.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard fields.count >= 3, fields.allSatisfy({ $0.count <= 256 }), fields[1].hasPrefix("_adb"),
                  let address = AdbSerial.address(fields[2]) else { continue }
            out.append(MdnsService(name: fields[0], type: fields[1].hasSuffix(".") ? String(fields[1].dropLast()) : fields[1],
                                   address: address))
        }
        return out
    }
}

/// When to try reconnecting a wirelessly paired device whose USB went away: every
/// 5 s for a minute, then every 60 s only while the Android tab is open. Pure, with
/// the time passed in; the hub runs `adb mdns services` and `adb connect` (5 s
/// timeout, it hangs on unreachable addresses) for what `due` returns.
public struct WirelessReconnect: Sendable {
    public static let fastInterval: TimeInterval = 5
    public static let fastWindow: TimeInterval = 60
    public static let slowInterval: TimeInterval = 60

    private struct Attempt: Sendable { var started: TimeInterval; var next: TimeInterval }
    private var pending: [DeviceID: Attempt] = [:]

    public init() {}

    public var waiting: Set<DeviceID> { Set(pending.keys) }

    /// The device lost its last transport and is paired for wireless debugging.
    public mutating func lost(_ id: DeviceID, now: TimeInterval) {
        guard pending[id] == nil else { return }
        pending[id] = Attempt(started: now, next: now + Self.fastInterval)
    }

    /// Back, over any transport, or forgotten: no more attempts.
    public mutating func cancel(_ id: DeviceID) { pending[id] = nil }

    /// Devices to try now; each one's next attempt is scheduled.
    public mutating func due(now: TimeInterval, tabOpen: Bool) -> [DeviceID] {
        var out: [DeviceID] = []
        for (id, a) in pending where now >= a.next {
            let fast = now - a.started <= Self.fastWindow
            guard fast || tabOpen else { continue }
            out.append(id)
            pending[id]?.next = now + (fast ? Self.fastInterval : Self.slowInterval)
        }
        return out.sorted()
    }

    /// When `due` next has something; nil when nothing would run (tab closed, past the
    /// first minute), so no timer is needed.
    public func nextWake(now: TimeInterval, tabOpen: Bool) -> TimeInterval? {
        pending.values.compactMap { a -> TimeInterval? in
            if a.next - a.started <= Self.fastWindow || tabOpen { return max(a.next, now) }
            return nil
        }.min()
    }
}
