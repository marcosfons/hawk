import Foundation

/// The one place that knows about devices: it owns the adb server supervisor, the
/// device registry, the call slots and the Wi-Fi reconnect schedule, and hands out
/// `DeviceSession`s. The interface only reads its finished snapshots.
///
/// With the Android tab closed it runs nothing of its own: the server's device watch
/// (idle until something changes) wakes it, plus a timer only while a restart grace
/// or a first-minute Wi-Fi reconnect is pending.
public actor AndroidHub {
    public struct Snapshot: Sendable, Equatable {
        /// Connected first, then most recently seen.
        public var devices: [Device] = []
        public var events: [DeviceID: [DeviceEvent]] = [:]
        public var server = AdbServer.Status()
        /// When each device's package index was last read: re-read `packages(for:)` when it changes.
        public var packagesDate: [DeviceID: Date] = [:]
        public init() {}
    }

    public nonisolated let snapshots: AsyncStream<Snapshot>
    public let server: AdbServer

    private let continuation: AsyncStream<Snapshot>.Continuation
    private var registry: DeviceRegistry
    private var reconnect = WirelessReconnect()
    private let slots = AdbSlots()
    private var serverStatus = AdbServer.Status()
    private var resolving: Set<String> = []
    private var tabOpen = false
    private var timer: Task<Void, Never>?
    private var listeners: [Task<Void, Never>] = []
    private var lastSnapshot: Snapshot?
    /// Where known devices and their events are kept; nil keeps nothing (tests).
    public nonisolated let store: DeviceStore?
    private var saved: [DeviceID: Device] = [:]
    /// The newest event written per device (lists are capped, so counts stop changing).
    private var savedEvents: [DeviceID: DeviceEvent] = [:]
    /// Saves in the order they were made, so an older record never lands last.
    private let saves: AsyncStream<(DeviceID, String, Data)>.Continuation

    private var packageIndexes: [DeviceID: PackageIndex] = [:]
    private var live: Set<DeviceID> = []
    private var readingPackages: Set<DeviceID> = []

    static let deviceFile = "device.json"
    static let eventsFile = "events.json"
    static let packagesFile = "packages.json"

    public init(server: AdbServer = AdbServer(), store: DeviceStore? = DeviceStore()) {
        self.server = server
        self.store = store
        registry = DeviceRegistry()
        (snapshots, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (queue, saves) = AsyncStream.makeStream(of: (DeviceID, String, Data).self)
        self.saves = saves
        if let store {
            Task(priority: .utility) {
                for await (id, name, data) in queue { await store.save(data, as: name, for: id) }
            }
        }
    }

    /// Once, at launch: load the devices seen before, then supervise adb and listen to it.
    public func start() async {
        guard listeners.isEmpty else { return }
        if let store {
            let devices = await store.loadAll(Device.self, Self.deviceFile)
            var events: [DeviceID: [DeviceEvent]] = [:]
            for d in devices {
                events[d.id] = await store.load([DeviceEvent].self, Self.eventsFile, for: d.id)
                packageIndexes[d.id] = await store.load(PackageIndex.self, Self.packagesFile, for: d.id)
            }
            registry = DeviceRegistry(devices: devices, events: events)
            saved = registry.devices
            savedEvents = registry.events.compactMapValues(\.last)
        }
        let server = server
        listeners = [
            Task(priority: .utility) { [weak self] in
                for await status in server.statusUpdates { await self?.serverChanged(status) }
            },
            Task(priority: .utility) { [weak self] in
                for await list in server.deviceLists { await self?.received(list) }
            },
        ]
        publish()
        await server.launch()
    }

    public func setTabVisible(_ open: Bool) async {
        tabOpen = open
        await server.setTabVisible(open)
        scheduleTimer()
    }

    /// A session for this device; its calls fail fast while it is not usable.
    public func session(for id: DeviceID) async throws -> any DeviceSession {
        guard let adb = await server.process() else { throw AdbError.notInstalled }
        let server = server
        return AdbDeviceSession(id: id, adb: adb, slots: slots,
                                serial: { [weak self] in await self?.preferredSerial(id) },
                                timedOut: { await server.reportTimeout() })
    }

    public func preferredSerial(_ id: DeviceID) -> String? { registry.preferredSerial(for: id) }

    /// Every known device now (the connection doctor matches them against USB).
    public func devices() -> [Device] { Array(registry.devices.values) }

    /// The device's packages as last read (kept across launches).
    public func packages(for id: DeviceID) -> PackageIndex? { packageIndexes[id] }

    /// Reads the package list again: on connect, and when a plan notices a change
    /// (an install, an uninstall, a package broadcast in logcat).
    public func refreshPackages(_ id: DeviceID) async {
        guard !readingPackages.contains(id) else { return }
        readingPackages.insert(id)
        defer { readingPackages.remove(id) }
        do {
            let parts = try await session(for: id).shellBatch(PackageIndex.parts, timeout: .seconds(15))
            var index = PackageIndex.parse(parts)
            guard !index.packages.isEmpty else { return Log.app.warning("Android package list came back empty") }
            // Labels come from elsewhere (plan B); a fresh read keeps them.
            for (name, old) in packageIndexes[id]?.packages ?? [:] where old.label != nil { index.setLabel(old.label, for: name) }
            packageIndexes[id] = index
            if store != nil, let data = try? JSONEncoder().encode(index) { saves.yield((id, Self.packagesFile, data)) }
            Log.app.info("Android package list read: \(index.packages.count) packages")
            publish()
        } catch {
            Log.app.warning("Could not read an Android package list: \((error as? AdbError)?.summary ?? error.localizedDescription)")
        }
    }

    /// A plan that learned labels (B's helper) stores them in the shared index.
    public func setLabels(_ labels: [String: String], for id: DeviceID) {
        guard var index = packageIndexes[id] else { return }
        for (name, label) in labels { index.setLabel(label, for: name) }
        packageIndexes[id] = index
        if store != nil, let data = try? JSONEncoder().encode(index) { saves.yield((id, Self.packagesFile, data)) }
        publish()
    }

    public func setNickname(_ name: String?, for id: DeviceID) {
        registry.setNickname(name, for: id)
        publish()
    }

    /// Removes a disconnected device and its folder.
    @discardableResult
    public func forget(_ id: DeviceID) async -> Bool {
        guard registry.forget(id) else { return false }
        reconnect.cancel(id)
        saved[id] = nil
        savedEvents[id] = nil
        packageIndexes[id] = nil
        await store?.remove(id)
        publish()
        return true
    }

    /// Writes what is queued now (Hawk is quitting).
    public func flush() async { await store?.flush() }

    // MARK: -

    private var now: Date { Date() }

    private func received(_ list: [AdbDeviceLine]) {
        // The first list can arrive before the "running" status (two streams), and the
        // watch sends again only on a change, so lists are taken whatever the status;
        // only a late one after the user stopped the server is ignored.
        guard serverStatus.state != .stopped(byUser: true) else { return }
        handle(registry.apply(list, now: now))
        resolveIdentities()
    }

    private func serverChanged(_ status: AdbServer.Status) {
        let wasRunning: Bool
        if case .running = serverStatus.state { wasRunning = true } else { wasRunning = false }
        serverStatus = status
        if wasRunning, !Self.isRunning(status.state) {
            handle(registry.serverWentDown(expectBack: status.state != .stopped(byUser: true), now: now))
        }
        publish()
    }

    private static func isRunning(_ state: ServerPolicy.State) -> Bool {
        if case .running = state { return true }
        return false
    }

    private func handle(_ events: [DeviceEvent]) {
        let t = now.timeIntervalSinceReferenceDate
        for e in events {
            switch e.kind {
            case .disconnected:
                if registry.devices[e.device]?.wirelessPaired == true { reconnect.lost(e.device, now: t) }
            case .connected, .transportAdded:
                reconnect.cancel(e.device)
            default:
                break
            }
            Log.app.info("Android device: \(e.summary)")
        }
        publish()
        scheduleTimer()
    }

    /// One `getprop ro.serialno` per new usable transport, through the call slots.
    private func resolveIdentities() {
        let todo = registry.needsIdentity.subtracting(resolving)
        guard !todo.isEmpty else { return }
        resolving.formUnion(todo)
        let server = server, slots = slots
        for serial in todo {
            Task(priority: .utility) { [weak self] in
                var found: String?
                if let adb = await server.process(), ShellQuote.isSerial(serial) {
                    let key = DeviceID(serial)
                    if (try? await slots.acquire(key)) != nil {
                        let out = try? await adb.run(["-s", serial, "shell", "getprop ro.serialno"], timeout: .seconds(5))
                        await slots.release(key)
                        if let out, out.status == 0 { found = Self.serialNumber(out.text) }
                    }
                }
                await self?.resolved(serial, found)
            }
        }
    }

    /// `ro.serialno` as printed, or nil if it is not a plausible one (then the
    /// transport keeps its guessed identity).
    static func serialNumber(_ output: String) -> String? {
        let s = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 64, ShellQuote.isSerial(s) else { return nil }
        return s
    }

    private func resolved(_ serial: String, _ number: String?) {
        resolving.remove(serial)
        guard registry.needsIdentity.contains(serial) else { return }
        // Unreadable: keep the guess rather than ask again on every list.
        let id = number.map(DeviceID.init) ?? registry.devices.values.first { $0.transports.contains { $0.serial == serial } }?.id
        guard let id else { return }
        handle(registry.resolve(serial: serial, as: id, now: now))
    }

    private func tick() async {
        handle(registry.expireRestart(now: now))
        let due = reconnect.due(now: now.timeIntervalSinceReferenceDate, tabOpen: tabOpen)
        for id in due { await tryReconnect(id) }
        scheduleTimer()
    }

    /// `adb mdns services` to find where the phone is now, else its last address;
    /// then `adb connect` with a short timeout (it hangs on unreachable addresses).
    private func tryReconnect(_ id: DeviceID) async {
        guard let adb = await server.process(), Self.isRunning(serverStatus.state) else { return }
        var address = registry.devices[id]?.lastWirelessAddress
        if let out = try? await adb.run(["mdns", "services"], timeout: .seconds(5)),
           let service = MdnsService.parse(out.text).first(where: { $0.type == MdnsService.connectType && $0.serialNumber == id.rawValue }) {
            address = service.address
        }
        guard let address, AdbSerial.address(address) != nil else { return }
        Log.app.debug("Trying to reconnect an Android device over Wi-Fi")
        _ = try? await adb.run(["connect", address], timeout: .seconds(5))
    }

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        let t = now.timeIntervalSinceReferenceDate
        let wakes = [registry.restartDeadline?.timeIntervalSinceReferenceDate, reconnect.nextWake(now: t, tabOpen: tabOpen)].compactMap { $0 }
        guard let at = wakes.min() else { return }
        timer = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, at - t)), tolerance: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await self?.tick()
        }
    }

    private func publish() {
        var s = Snapshot()
        s.devices = registry.devices.values.sorted { a, b in
            a.isConnected != b.isConnected ? a.isConnected : a.lastSeen > b.lastSeen
        }
        s.events = registry.events
        s.server = serverStatus
        s.packagesDate = packageIndexes.mapValues(\.date)
        noticeNewlyLive()
        guard s != lastSnapshot else { return }
        lastSnapshot = s
        continuation.yield(s)
        persist()
    }

    /// A device that just became usable, with its identity settled, gets its packages read.
    private func noticeNewlyLive() {
        let now = Set(registry.devices.keys.filter { id in
            guard let serial = registry.preferredSerial(for: id) else { return false }
            return !registry.needsIdentity.contains(serial)
        })
        for id in now.subtracting(live) { Task(priority: .utility) { [weak self] in await self?.refreshPackages(id) } }
        live = now
    }

    /// Queues the devices and event lists that changed; the store coalesces the writes.
    private func persist() {
        guard store != nil else { return }
        let encoder = JSONEncoder()
        for (id, device) in registry.devices where saved[id] != device {
            saved[id] = device
            if let data = try? encoder.encode(device) { saves.yield((id, Self.deviceFile, data)) }
        }
        for (id, list) in registry.events where list.last != savedEvents[id] {
            savedEvents[id] = list.last
            if let data = try? encoder.encode(list) { saves.yield((id, Self.eventsFile, data)) }
        }
    }
}
