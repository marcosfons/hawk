import Darwin
import Foundation

/// Supervises the adb server: finds adb, attaches to (or starts) the server, keeps the
/// device watch open, and recovers when someone else kills or restarts it. Every
/// automatic action comes from `ServerPolicy`; this actor only carries them out and
/// reports what happened. One timer at most, and only while something is scheduled.
public actor AdbServer {
    public struct Status: Sendable, Equatable {
        public var state: ServerPolicy.State = .stopped(byUser: false)
        public var installation: AdbInstallation?
        /// Running, but started by another client while Hawk's was stopped.
        public var startedByOther = false
        /// What Hawk is doing right now, for the header ("Restarting").
        public var activity: String?
        /// The adb that was found; false only once the search ran and found nothing.
        public var installed: Bool { installation?.chosen != nil }

        public init() {}
    }

    /// Every status change, newest first if the reader falls behind.
    public nonisolated let statusUpdates: AsyncStream<Status>
    /// Every device list from the watch (the full list each time).
    public nonisolated let deviceLists: AsyncStream<[AdbDeviceLine]>

    private let statusContinuation: AsyncStream<Status>.Continuation
    private let devicesContinuation: AsyncStream<[AdbDeviceLine]>.Continuation
    private var status = Status()
    private var policy = ServerPolicy()
    private var locator: AdbLocator
    private let socket: AdbSocket
    private let children: ChildProcesses
    private let defaults: UserDefaults
    private var adb: AdbProcess?
    private var timer: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    private var tracking: Task<Void, Never>?
    /// Bumped whenever Hawk itself closes the watch, so its end is not taken as a loss.
    private var trackingGeneration = 0
    private var lastPublished: Status?

    private static let stoppedKey = "androidAdbStoppedByUser"
    /// While the tab is open: a health probe when running, a look for a server someone
    /// else started when stopped. Nothing while it is closed.
    private static let watchInterval: Duration = .seconds(30)

    public init(locator: AdbLocator = AdbLocator(), socket: AdbSocket = AdbSocket(), children: ChildProcesses = .shared,
                defaults: UserDefaults = .standard) {
        self.locator = locator
        self.socket = socket
        self.children = children
        self.defaults = defaults
        (statusUpdates, statusContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (deviceLists, devicesContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// Called once when Hawk starts.
    public func launch() async {
        relocate()
        guard status.installed else { return }
        await apply(policy.handle(.launch(stoppedByUser: defaults.bool(forKey: Self.stoppedKey)), now: now))
    }

    public func setTabVisible(_ open: Bool) async {
        if open, !status.installed { relocate() }
        await apply(policy.handle(.tabVisible(open), now: now))
        watch?.cancel()
        watch = nil
        guard open, status.installed else { return }
        watch = Task(priority: .utility) { [weak self] in
            await self?.lookAtServer()
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.watchInterval, tolerance: .seconds(5))
                guard !Task.isCancelled else { return }
                await self?.lookAtServer()
            }
        }
    }

    public func userStart() async {
        defaults.set(false, forKey: Self.stoppedKey)
        relocate()
        await apply(policy.handle(.userStart, now: now))
    }

    public func userStop() async {
        defaults.set(true, forKey: Self.stoppedKey)
        await apply(policy.handle(.userStop, now: now))
    }

    public func userRestart() async {
        defaults.set(false, forKey: Self.stoppedKey)
        relocate()
        await apply(policy.handle(.userRestart, now: now))
    }

    /// A device call timed out: the server may be hung. Checked at once.
    public func reportTimeout() async {
        guard case .running = policy.state else { return }
        await probe()
    }

    /// The status now, for pages that need it once rather than as a stream.
    public func currentStatus() -> Status { status }

    /// The adb Hawk runs, if found.
    public func process() -> AdbProcess? { adb }

    // MARK: - Carrying out the policy

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func apply(_ action: ServerPolicy.Action) async {
        switch action {
        case .none: break
        case .start: await start()
        case .probe: await probe()
        case .stop: await stopServer()
        case .restart:
            await stopServer()
            await start()
        }
        publish()
        scheduleTimer()
    }

    private func handle(_ event: ServerPolicy.Event) async {
        await apply(policy.handle(event, now: now))
    }

    /// Attach if a server answers; otherwise `adb start-server` and wait for it.
    private func start() async {
        guard let adb else { return await handle(.startFailed(.notInstalled)) }
        if let version = try? await socket.version(timeout: .seconds(3)) {
            Log.app.info("adb server already running (protocol \(version)); attached")
            return await answered(version)
        }
        setActivity("Starting adb")
        defer { setActivity(nil) }
        do {
            let out = try await adb.run(["start-server"], timeout: .seconds(10))
            // A mismatch can end in success: our start killed the other client's server.
            if case .versionMismatch? = AdbError.classify(status: 1, stderr: out.stderr) {
                Log.app.warning("adb version mismatch while starting the server")
                return await handle(.startFailed(AdbError.classify(status: 1, stderr: out.stderr) ?? .serverUnreachable))
            }
            if let error = out.error { return await handle(.startFailed(error)) }
        } catch let error as AdbError {
            return await handle(.startFailed(error))
        } catch {
            return
        }
        // start-server returns once the server listens; give it a moment to answer.
        for _ in 0..<10 {
            if let version = try? await socket.version(timeout: .seconds(2)) {
                Log.app.info("adb server started (protocol \(version))")
                return await answered(version)
            }
            try? await Task.sleep(for: .milliseconds(300))
        }
        await handle(.startFailed(.serverUnreachable))
    }

    private func probe() async {
        do {
            let version = try await socket.version(timeout: .seconds(3))
            await answered(version)
        } catch AdbError.timeout {
            Log.app.warning("adb server did not answer in 3 s")
            await handle(.unresponsive(reason: "Not answering"))
        } catch {
            await handle(.lost(reason: (error as? AdbError)?.summary ?? "Not reachable"))
        }
    }

    private func answered(_ version: Int) async {
        await handle(.answered(version: version))
        // A start that finishes after the user pressed Stop does not reopen the watch.
        if case .running = policy.state { startTracking() }
    }

    /// While tab is open: probe a running server; look for one started by someone else.
    private func lookAtServer() async {
        switch policy.state {
        case .running:
            await probe()
        case .stopped(byUser: true):
            if let version = try? await socket.version(timeout: .seconds(2)) {
                Log.app.info("adb server started by another client")
                await handle(.foundRunning(version: version))
                startTracking()
            }
        default:
            break
        }
    }

    private func startTracking() {
        guard tracking == nil else { return }
        trackingGeneration += 1
        let generation = trackingGeneration
        let lists = socket.trackDevices()
        tracking = Task(priority: .utility) { [weak self] in
            var reason = "adb server closed the connection"
            do {
                for try await list in lists { await self?.received(list) }
            } catch {
                reason = (error as? AdbError)?.summary ?? reason
            }
            await self?.trackingEnded(generation: generation, reason: reason)
        }
    }

    private func received(_ list: [AdbDeviceLine]) {
        devicesContinuation.yield(list)
    }

    private func trackingEnded(generation: Int, reason: String) async {
        guard generation == trackingGeneration else { return }
        tracking = nil
        Log.app.info("adb device watch ended: \(reason)")
        await handle(.lost(reason: reason))
    }

    private func stopTracking() {
        trackingGeneration += 1
        tracking?.cancel()
        tracking = nil
    }

    /// `adb kill-server`; if the server is still there (hung), its process by PID, only
    /// if that process is an adb; then wait for the port to free.
    private func stopServer() async {
        stopTracking()
        setActivity("Stopping adb")
        defer { setActivity(nil) }
        if let adb { _ = try? await adb.run(["kill-server"], timeout: .seconds(5)) }
        if await socket.isListening() {
            Log.app.warning("adb kill-server left the server running; stopping it by PID")
            await killListener()
        }
        for _ in 0..<20 {
            guard await socket.isListening(timeout: .milliseconds(500)) else { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        Log.app.warning("Port \(socket.port) still busy after stopping adb")
    }

    private func killListener() async {
        let lsof = AdbProcess(executable: "/usr/sbin/lsof", children: children)
        guard let out = try? await lsof.run(["-nP", "-tiTCP:\(socket.port)", "-sTCP:LISTEN"], timeout: .seconds(5)) else { return }
        let pids = out.text.split(whereSeparator: \.isNewline).compactMap { pid_t($0) }.filter { Self.isAdb($0) }
        for pid in pids { kill(pid, SIGTERM) }
        try? await Task.sleep(for: .seconds(2))
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Only an adb is ever killed by PID, whatever holds the port.
    static func isAdb(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return (path as NSString).lastPathComponent == "adb"
    }

    private func relocate() {
        let found = locator.locate()
        status.installation = found
        adb = found.chosen.map { AdbProcess(executable: $0.path, children: children) }
        if let chosen = found.chosen {
            Log.app.info("adb \(chosen.version) found (\(found.others.count) other copies)")
        } else {
            Log.app.info("adb not found")
        }
        for warning in found.warnings { Log.app.warning(warning) }
        publish()
    }

    private func setActivity(_ text: String?) {
        status.activity = text
        publish()
    }

    private func publish() {
        if policy.state != status.state { Log.app.info("adb server: \(Self.describe(policy.state))") }
        status.state = policy.state
        status.startedByOther = policy.startedByOther
        guard status != lastPublished else { return }
        lastPublished = status
        statusContinuation.yield(status)
    }

    /// For the log: the state without device data, rounded times.
    static func describe(_ state: ServerPolicy.State) -> String {
        switch state {
        case .stopped(let byUser): byUser ? "stopped by the user" : "not started"
        case .starting: "starting"
        case .running(let version): "running (protocol \(version))"
        case .unhealthy(let reason): "not answering (\(reason))"
        case .backingOff(let until, let attempt, let reason):
            String(format: "retrying in %.1f s, attempt %d (%@)", until - ProcessInfo.processInfo.systemUptime, attempt, reason)
        case .failing(let reason, _): "failing (\(reason)); retries every 60 s while the Android tab is open"
        case .versionMismatch(let server, let client): "version mismatch (server \(server ?? "?"), client \(client ?? "?"))"
        }
    }

    private func scheduleTimer() {
        timer?.cancel()
        timer = nil
        guard let at = policy.retryAt else { return }
        let delay = max(0, at - now)
        timer = Task(priority: .utility) { [weak self] in
            try? await Task.sleep(for: .seconds(delay), tolerance: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.handle(.tick)
        }
    }
}
