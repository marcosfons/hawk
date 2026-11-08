import Foundation

/// Every device Hawk has seen, built from the device watch's lists. Pure: lists and
/// the time come in, events come out; the hub that owns it runs the shell calls it
/// asks for (`needsIdentity`) and reports back with `resolve`.
///
/// - One device per `ro.serialno`, with one transport per way adb reaches it.
/// - Devices never disappear: unplugged ones stay, with `lastSeen`.
/// - A transport change is not a disconnect: USB to Wi-Fi is "Unplugged from USB",
///   "Reconnected over Wi-Fi", and calls move to the remaining transport.
/// - A server restart is one event, not a disconnect and reconnect of every device.
public struct DeviceRegistry: Sendable {
    public private(set) var devices: [DeviceID: Device] = [:]
    public private(set) var events: [DeviceID: [DeviceEvent]] = [:]
    /// Usable transports whose `ro.serialno` has not been read yet.
    public private(set) var needsIdentity: Set<String> = []
    /// While the server restarts, devices that were connected and are not back yet;
    /// they become disconnected only at `restartDeadline`.
    public private(set) var restartDeadline: Date?

    public static let maxEvents = 500
    /// How long devices may take to reappear after the server restarts.
    public static let restartGrace: TimeInterval = 5

    /// adb serial -> the device its transport belongs to.
    private var owner: [String: DeviceID] = [:]
    private var verified: Set<String> = []
    private var restarting: Set<DeviceID> = []

    public init(devices: [Device] = [], events: [DeviceID: [DeviceEvent]] = [:]) {
        for var d in devices {
            d.transports = []
            self.devices[d.id] = d
        }
        self.events = events
    }

    /// A full device list from the watch (or a `devices -l` resync).
    public mutating func apply(_ lines: [AdbDeviceLine], now: Date) -> [DeviceEvent] {
        let before = devices
        let present = Dictionary(lines.map { ($0.serial, $0) }, uniquingKeysWith: { a, _ in a })

        for (serial, id) in owner where present[serial] == nil {
            // It was there until now: "last seen" is the moment it went.
            devices[id]?.lastSeen = now
            devices[id]?.transports.removeAll { $0.serial == serial }
            owner[serial] = nil
            needsIdentity.remove(serial)
            verified.remove(serial)
        }
        for line in lines {
            let kind = TransportKind.of(line)
            let state = TransportState(line.state)
            let id = owner[line.serial] ?? guessID(line.serial)
            owner[line.serial] = id
            var device = devices[id] ?? Device(id: id, lastSeen: now)
            let transport = Transport(serial: line.serial, kind: kind, state: state, transportID: line.transportID)
            if let i = device.transports.firstIndex(where: { $0.serial == line.serial }) {
                device.transports[i] = transport
            } else {
                device.transports.append(transport)
            }
            if let model = line.model { device.model = model }
            if let product = line.product { device.product = product }
            if kind == .wifi, state == .device {
                device.wirelessPaired = true
                if let address = AdbSerial.address(line.serial) { device.lastWirelessAddress = address }
            }
            devices[id] = device
            if state == .device, kind != .emulator, !verified.contains(line.serial) { needsIdentity.insert(line.serial) }
            if state != .device { needsIdentity.remove(line.serial) }
        }
        for id in devices.keys where devices[id]?.isConnected == true { devices[id]?.lastSeen = now }
        // Back from a server restart: not a new connection.
        let returning = restarting.intersection(devices.values.filter(\.isConnected).map(\.id))
        restarting.subtract(returning)
        if restarting.isEmpty { restartDeadline = nil }
        return record(diff(before, quiet: returning, now: now))
    }

    /// The hub read `ro.serialno` over this transport. A guess that was wrong (an
    /// `ip:port` serial, a USB serial that is not the serial number) moves the
    /// transport to the right device, merging the provisional one into it.
    public mutating func resolve(serial: String, as id: DeviceID, now: Date) -> [DeviceEvent] {
        needsIdentity.remove(serial)
        guard let current = owner[serial], let transport = devices[current]?.transports.first(where: { $0.serial == serial }) else { return [] }
        verified.insert(serial)
        guard current != id else { return [] }
        let before = devices
        var provisional = devices[current]
        provisional?.transports.removeAll { $0.serial == serial }
        var target = devices[id] ?? Device(id: id, model: provisional?.model, product: provisional?.product, lastSeen: now)
        target.transports.append(transport)
        if transport.kind == .wifi { target.wirelessPaired = true }
        if let address = AdbSerial.address(serial), transport.state == .device { target.lastWirelessAddress = address }
        target.lastSeen = now
        devices[id] = target
        owner[serial] = id
        // A device that existed only because of the wrong guess is folded in, history and all.
        if let p = provisional, p.transports.isEmpty, p.nickname == nil {
            devices[current] = nil
            let moved = (events[current] ?? []).map { DeviceEvent(date: $0.date, device: id, kind: $0.kind) }
            events[current] = nil
            events[id] = Array(((events[id] ?? []) + moved).sorted { $0.date < $1.date }.suffix(Self.maxEvents))
            var trimmedBefore = before
            trimmedBefore[current] = nil
            return record(diff(trimmedBefore, quiet: [], now: now))
        }
        devices[current] = provisional
        return record(diff(before, quiet: [], now: now))
    }

    /// The server went away. Expected back (restarted by Hawk or someone else): one
    /// "adb server restarted" event per connected device, and devices that are not
    /// back by `restartDeadline` become disconnected. Stopped for good: disconnected now.
    public mutating func serverWentDown(expectBack: Bool, now: Date) -> [DeviceEvent] {
        let connected = devices.values.filter(\.isConnected).map(\.id)
        let before = devices
        for id in connected {
            devices[id]?.transports = []
            devices[id]?.lastSeen = now
        }
        owner = [:]
        verified = []
        needsIdentity = []
        guard expectBack else {
            restarting = []
            restartDeadline = nil
            return record(diff(before, quiet: [], now: now))
        }
        restarting.formUnion(connected)
        if !connected.isEmpty { restartDeadline = now + Self.restartGrace }
        return record(connected.sorted().map { DeviceEvent(date: now, device: $0, kind: .serverRestarted) })
    }

    /// At `restartDeadline`: devices that did not come back are disconnected.
    public mutating func expireRestart(now: Date) -> [DeviceEvent] {
        guard let deadline = restartDeadline, now >= deadline else { return [] }
        restartDeadline = nil
        let gone = restarting.filter { devices[$0]?.isConnected == false }.sorted()
        restarting = []
        return record(gone.map { DeviceEvent(date: now, device: $0, kind: .disconnected) })
    }

    public mutating func setNickname(_ name: String?, for id: DeviceID) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64)
        devices[id]?.nickname = trimmed.flatMap { $0.isEmpty ? nil : String($0) }
    }

    /// Forgetting is by hand only, and only a device that is not connected.
    @discardableResult
    public mutating func forget(_ id: DeviceID) -> Bool {
        guard let d = devices[id], !d.isConnected else { return false }
        devices[id] = nil
        events[id] = nil
        restarting.remove(id)
        return true
    }

    /// The serial calls for this device go through right now, if it can take calls.
    public func preferredSerial(for id: DeviceID) -> String? {
        guard let t = devices[id]?.preferred, t.state == .device else { return nil }
        return t.serial
    }

    // MARK: -

    private func guessID(_ serial: String) -> DeviceID {
        if let number = AdbSerial.serialNumber(fromWireless: serial) { return DeviceID(number) }
        if AdbSerial.address(serial) != nil,
           let known = devices.values.first(where: { $0.lastWirelessAddress == serial }) { return known.id }
        return DeviceID(serial)
    }

    /// Events between two snapshots; devices in `quiet` reconnecting raise no event.
    private func diff(_ before: [DeviceID: Device], quiet: Set<DeviceID>, now: Date) -> [DeviceEvent] {
        var out: [DeviceEvent] = []
        for id in Set(before.keys).union(devices.keys).sorted() {
            let old = before[id], new = devices[id]
            let oldKinds = Set(old?.transports.map(\.kind) ?? []), newKinds = Set(new?.transports.map(\.kind) ?? [])
            func add(_ kind: DeviceEvent.Kind) { out.append(DeviceEvent(date: now, device: id, kind: kind)) }
            switch (old?.isConnected ?? false, new?.isConnected ?? false) {
            case (false, true):
                if !quiet.contains(id), let k = new?.preferred?.kind { add(.connected(k)) }
            case (true, false):
                add(.disconnected)
            case (true, true):
                for k in oldKinds.subtracting(newKinds).sorted() { add(.transportRemoved(k)) }
                for k in newKinds.subtracting(oldKinds).sorted() { add(.transportAdded(k)) }
            case (false, false):
                break
            }
            if let from = old?.state, let to = new?.state, from != to {
                add(.stateChanged(from: from, to: to))
            }
        }
        return out
    }

    private mutating func record(_ new: [DeviceEvent]) -> [DeviceEvent] {
        for e in new {
            var list = events[e.device] ?? []
            list.append(e)
            if list.count > Self.maxEvents { list.removeFirst(list.count - Self.maxEvents) }
            events[e.device] = list
        }
        return new
    }
}
