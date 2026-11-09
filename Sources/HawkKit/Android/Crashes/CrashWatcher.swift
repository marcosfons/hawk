import Foundation

/// Catches every ANR (and crash) without logcat (requirements 5.1): on each
/// connection the DropBox listing is read in full and new entries imported; while a
/// device stays connected, a short listing of today's entries every 60 s, whatever
/// is on screen, and the full entry only for new ones. For a new ANR, the logcat
/// lines before it are read once from the phone's buffer. Nothing streams.
public actor CrashWatcher {
    public struct Alert: Sendable {
        public let device: DeviceID
        public let deviceName: String
        public let record: CrashRecord
    }

    public nonisolated let alerts: AsyncStream<Alert>
    private let continuation: AsyncStream<Alert>.Continuation
    /// Battery and storage, read in the same shell call as the listing every
    /// `DeviceHealth.interval` (plan F5): no extra call on the phone.
    public nonisolated let health: AsyncStream<(device: DeviceID, name: String, reading: DeviceHealth.Reading)>
    private let healthContinuation: AsyncStream<(device: DeviceID, name: String, reading: DeviceHealth.Reading)>.Continuation
    private var lastHealth: [DeviceID: Date] = [:]
    private let hub: AndroidHub
    private var logs: [DeviceID: CrashLog] = [:]
    private var live: [DeviceID: String] = [:]
    private var loop: Task<Void, Never>?
    private var checking: Set<DeviceID> = []
    /// Packages whose crashes alert too (ANRs always do).
    public var watched: Set<String> = []

    public static let interval: Duration = .seconds(60)
    static let file = "crashes.json"

    public init(hub: AndroidHub) {
        self.hub = hub
        (alerts, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(50))
        (health, healthContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(20))
    }

    public func setWatched(_ packages: Set<String>) { watched = packages }

    /// The usable devices now. A newly usable one gets a full import at once; the
    /// 60 s loop runs only while there is at least one.
    public func setLive(_ devices: [Device]) {
        let now = Dictionary(devices.filter { $0.state == .device }.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let added = Set(now.keys).subtracting(live.keys)
        live = now
        for id in lastHealth.keys where now[id] == nil { lastHealth[id] = nil }
        for id in added { Task(priority: .utility) { await self.check(id, full: true) } }
        if live.isEmpty {
            loop?.cancel()
            loop = nil
        } else if loop == nil {
            loop = Task(priority: .utility) { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.interval, tolerance: .seconds(10))
                    guard !Task.isCancelled, let self else { return }
                    for id in await self.liveIDs() { await self.check(id, full: false) }
                }
            }
        }
    }

    public func log(for id: DeviceID) async -> CrashLog {
        if let log = logs[id] { return log }
        let kept = await hub.store?.load(CrashLog.self, Self.file, for: id) ?? CrashLog()
        logs[id] = kept
        return kept
    }

    private func liveIDs() -> [DeviceID] { Array(live.keys) }

    func check(_ id: DeviceID, full: Bool) async {
        guard !checking.contains(id), let name = live[id] else { return }
        checking.insert(id)
        defer { checking.remove(id) }
        var log = await log(for: id)
        do {
            let session = try await hub.session(for: id)
            let withHealth = full || Date().timeIntervalSince(lastHealth[id] ?? .distantPast) >= DeviceHealth.interval
            let script = (full ? DropBox.fullListing : DropBox.recentListing) + (withHealth ? "; " + DeviceHealth.probe : "")
            let output = try await session.shell(script, timeout: .seconds(15))
            let (listing, reading) = DeviceHealth.split(output.stdout)
            if let reading {
                lastHealth[id] = Date()
                healthContinuation.yield((id, name, reading))
            }
            let fresh = log.new(DropBox.parseListing(listing))
            guard !fresh.isEmpty || log.since == nil else { return }
            var fetched: [CrashRecord] = []
            for tag in Set(fresh.map(\.tag)).sorted() {
                let out = try await session.shell("dumpsys dropbox --print \(ShellQuote.quote(tag)) 2>/dev/null", timeout: .seconds(20))
                let keys = Set(fresh.filter { $0.tag == tag }.map(\.key))
                fetched += DropBox.parseEntries(out.stdout).filter { keys.contains($0.key) }
            }
            let alerting = log.add(fetched, now: Date())
            log.markKnown(fresh)
            for r in alerting where r.kind == .anr {
                let lines = try? await session.shell(DropBox.logcatBefore(r.date), timeout: .seconds(10))
                let before = (lines?.stdout ?? "").split(separator: "\n").map(String.init).filter { !$0.hasPrefix("---------") }
                log.setLogcat(before, for: r.key)
            }
            logs[id] = log
            await hub.store?.save(log, as: Self.file, for: id)
            if !fetched.isEmpty { Log.app.info("Android crash watch: \(fetched.count) new entries") }
            for r in alerting where r.kind == .anr || r.package.map(watched.contains) == true {
                continuation.yield(Alert(device: id, deviceName: name, record: log.records.first { $0.key == r.key } ?? r))
            }
        } catch {
            Log.app.warning("Android crash watch failed: \((error as? AdbError)?.summary ?? error.localizedDescription)")
        }
    }
}
