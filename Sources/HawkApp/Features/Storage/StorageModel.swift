//
//  StorageModel.swift
//  Hawk
//
//  The Storage tab's state. Sizes come from the storage registry's own scanner
//  (mac-scan -> scans/latest.json); Hawk reads that file, watches it for changes,
//  and asks mac-scan to refresh, which re-measures only entries past their TTL.
//  Nothing here runs until the tab is first opened, and periodic work stops when
//  it is closed.
//

import AppKit
import HawkKit
import Foundation
import Observation

nonisolated struct DeletionRequest: Identifiable, Sendable {
    enum Action: Sendable {
        case path(String)
        case command(String)
        case dockerVolume(String)
    }
    let entryID: String
    let entryName: String
    let title: String
    let action: Action
    let bytes: Int64?
    let details: [String]
    let needsAcknowledgement: Bool
    var id: String {
        switch action {
        case .path(let p): "path:" + p
        case .command(let c): "cmd:" + c
        case .dockerVolume(let v): "vol:" + v
        }
    }
}

@Observable
final class StorageModel {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", safe = "Safe to clear", care = "With care", protected = "Protected", over = "Over limit"
        var id: String { rawValue }
    }

    let folder: URL
    private(set) var scan: StorageScan?
    private(set) var loadError: String?
    private(set) var growth: [String: Double] = [:]               // GB over 30 days
    private(set) var series: [String: [Double]] = [:]             // recent sizes, for sparklines
    private(set) var touched: [String: Date] = [:]                // path -> last activity
    private(set) var running = RunningState(bundleIDs: [], commandLines: [])
    private(set) var whatsapp: WhatsAppReport?
    private(set) var simulators: [SimulatorDevice] = []
    /// DerivedData folder -> the project it builds and when Xcode last opened it.
    private(set) var derived: [String: (project: String?, lastOpened: Date?)] = [:]
    private(set) var stremioCap: Int64?
    private(set) var docker: DockerState?
    private(set) var scanning = false
    /// Without Full Disk Access, WhatsApp and the Trash read as empty, for Hawk and for
    /// any scan it starts; then Hawk never starts scans on its own.
    private(set) var fullDiskAccess = hasFullDiskAccess()
    private(set) var whatsappNoAccess = false
    private(set) var whatsappBusy = false
    private(set) var working: Set<String> = []
    private(set) var message: String?
    var selection: String?
    var filter: Filter = .all
    var search = ""
    var pending: DeletionRequest?

    @ObservationIgnored private let worker = StorageWorker()
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastScanRun = Date.distantPast
    @ObservationIgnored private var lastDockerSizes = Date.distantPast
    @ObservationIgnored private var lastWhatsApp = Date.distantPast
    @ObservationIgnored private var lastRunning = Date.distantPast
    @ObservationIgnored private var lastDevTools = Date.distantPast

    static let scanEvery: TimeInterval = 1800
    static let dockerEvery: TimeInterval = 300
    static let dockerSizesEvery: TimeInterval = 1800
    static let whatsappEvery: TimeInterval = 1800
    /// What is running only feeds the delete guards (re-checked at the moment of deleting),
    /// so it need not be fresh to the second.
    static let runningEvery: TimeInterval = 30
    static let devToolsEvery: TimeInterval = 600

    init() {
        let path = UserDefaults.standard.string(forKey: "storageFolder") ?? "~/Library/Application Support/Hawk/storage"
        folder = URL(filePath: StorageRules.expand(path))
    }

    var scanURL: URL { folder.appending(path: "scans/latest.json") }
    var scannerURL: URL { folder.appending(path: "bin/mac-scan") }

    // MARK: Lifecycle

    func activate() {
        guard loop == nil else { return }
        if scan == nil { reload() }
        startWatching()
        loop = Task {
            while !Task.isCancelled {
                await periodic()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func deactivate() {
        loop?.cancel()
        loop = nil
        watcher?.cancel()
        watcher = nil
    }

    /// Every 10 s while the tab is open: whatever is due.
    private func periodic() async {
        let now = Date()
        if now.timeIntervalSince(lastRunning) > Self.runningEvery {
            lastRunning = now
            running = await worker.running(bundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
            fullDiskAccess = hasFullDiskAccess()
        }
        if now.timeIntervalSince(lastDevTools) > Self.devToolsEvery {
            lastDevTools = now
            simulators = await worker.simulators()
            stremioCap = Stremio.cacheCap()
        }
        if fullDiskAccess, now.timeIntervalSince(lastScanRun) > Self.scanEvery, (scan?.scannedAt).map({ now.timeIntervalSince($0) > Self.scanEvery }) ?? true {
            refresh()
        }
        if docker == nil || now.timeIntervalSince(docker?.measuredAt ?? .distantPast) > Self.dockerEvery {
            let sizes = now.timeIntervalSince(lastDockerSizes) > Self.dockerSizesEvery
            var state = await worker.docker(withSizes: sizes)
            if sizes, state.running { lastDockerSizes = now } else if let old = docker {
                // Keep the last known sizes between the slow measurements.
                for i in state.volumes.indices { state.volumes[i].bytes = old.volumes.first { $0.name == state.volumes[i].name }?.bytes }
            }
            docker = state
        }
        if now.timeIntervalSince(lastWhatsApp) > Self.whatsappEvery { refreshWhatsApp() }
    }

    func refreshWhatsApp() {
        guard !whatsappBusy else { return }
        whatsappBusy = true
        lastWhatsApp = Date()
        Task {
            if whatsapp == nil { whatsapp = await worker.whatsappCached() }
            switch await worker.whatsapp() {
            case .success(let fresh): whatsappNoAccess = false; if let fresh { whatsapp = fresh }
            case .failure: whatsappNoAccess = true
            }
            whatsappBusy = false
        }
    }

    // MARK: Scan

    func reload() {
        Task {
            let result = await worker.load(scan: scanURL, history: folder.appending(path: "scans/history.csv"))
            scan = result.scan
            loadError = result.error
            growth = result.growth
            series = result.series
            if selection == nil { selection = scan?.entries.filter { $0.risk != .never }.max { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }?.id }
            if let scan {
                touched = await worker.lastTouched(scan.entries.flatMap { e in e.children.map(\.path) })
                derived = await worker.derivedData(scan.entries.first { $0.id == "xcode-derived-data" }?.children.map(\.path) ?? [])
            }
        }
    }

    /// Runs mac-scan: TTL-respecting by default, `force` re-measures (optionally one entry).
    func refresh(force: Bool = false, only: String? = nil) {
        guard !scanning, FileManager.default.isExecutableFile(atPath: scannerURL.path) else { return }
        scanning = true
        lastScanRun = Date()
        Task {
            let ok = await worker.runScanner(scannerURL, force: force, only: only)
            scanning = false
            if !ok { message = "mac-scan did not finish; showing the previous scan" }
            reload()
        }
    }

    private func startWatching() {
        let dir = scanURL.deletingLastPathComponent().path
        let fd = open(dir, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: Queries

    func entry(_ id: String?) -> StorageEntry? { scan?.entries.first { $0.id == id } }

    /// The most recent activity among an entry's items.
    func lastUsed(_ entry: StorageEntry) -> Date? {
        entry.children.compactMap { c in c.lastUsed.flatMap(StorageScan.parseDate) ?? derived[c.path]?.lastOpened ?? touched[c.path] }.max()
    }

    func verdict(_ entry: StorageEntry, path: String) -> StorageRules.Verdict {
        StorageRules.verdict(entry: entry, path: path, running: running, lastTouched: touched[path])
    }

    var filtered: [StorageEntry] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return (scan?.entries ?? []).filter { e in
            let matches = switch filter {
            case .all: true
            case .safe: e.risk == .safe
            case .care: e.risk == .care
            case .protected: e.risk == .never
            case .over: e.state == "warn" || e.state == "crit"
            }
            return matches && (q.isEmpty || e.name.localizedCaseInsensitiveContains(q) || e.id.localizedCaseInsensitiveContains(q)
                               || (e.kind?.localizedCaseInsensitiveContains(q) ?? false))
        }
        .sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
    }

    // MARK: Deleting

    func requestDelete(_ entry: StorageEntry, child: StorageEntry.Child) {
        let v = verdict(entry, path: child.path)
        guard !v.isBlocked else { return }
        var details = [entry.onDelete.map { "If deleted: \($0)" }, entry.rebuildCost.map { "Getting it back: \($0)" }].compactMap { $0 }
        if case .caution(let why) = v { details.insert(why, at: 0) }
        details += entry.care.map { "Care: \($0)" }
        pending = DeletionRequest(entryID: entry.id, entryName: entry.name, title: "Delete \((child.path as NSString).lastPathComponent)?",
                                  action: .path(child.path), bytes: child.bytes, details: details,
                                  needsAcknowledgement: entry.risk == .care || v != .allowed)
    }

    func requestReclaim(_ entry: StorageEntry) {
        guard let command = StorageRules.runnableReclaim(entry) else { return }
        if let why = StorageRules.entryInUse(entry, running: running) { message = "Not now: \(why)"; return }
        let details = [entry.onDelete.map { "If deleted: \($0)" }, entry.rebuildCost.map { "Getting it back: \($0)" }].compactMap { $0 }
            + entry.care.map { "Care: \($0)" }
        pending = DeletionRequest(entryID: entry.id, entryName: entry.name, title: "Run the cleanup for \(entry.name)?",
                                  action: .command(command), bytes: entry.sizeBytes, details: details, needsAcknowledgement: entry.risk == .care)
    }

    func requestSimulatorDelete(_ device: SimulatorDevice) {
        guard !device.booted else { return }
        pending = DeletionRequest(entryID: "ios-simulators", entryName: "iOS simulator", title: "Delete the simulator \(device.name)?",
                                  action: .command("xcrun simctl delete \(device.udid)"), bytes: device.bytes,
                                  details: ["\(device.runtime), last used \(Format.ago(device.lastUsed)).",
                                            "Its apps and data go with it. Xcode can create a new one in seconds."],
                                  needsAcknowledgement: false)
    }

    func requestVolumeRemoval(_ volume: DockerState.Volume) {
        guard volume.containers.isEmpty else { return }
        let host = entry("docker-vm-disk").map { Format.bytes(Double($0.sizeBytes ?? 0)) } ?? "the VM disk"
        pending = DeletionRequest(entryID: "docker-volumes", entryName: "Docker volume", title: "Remove the volume \(volume.name)?",
                                  action: .dockerVolume(volume.name), bytes: volume.bytes,
                                  details: ["No container uses it. Its data is gone for good once removed.",
                                            "This frees space inside Docker's VM; the host disk image (\(host)) does not shrink, it only stops growing."],
                                  needsAcknowledgement: true)
    }

    func perform(_ request: DeletionRequest) {
        pending = nil
        working.insert(request.id)
        Task {
            let state = await worker.running(bundleIDs: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
            running = state
            // Check again at the last moment: an app may have opened since the sheet appeared.
            if let e = entry(request.entryID) {
                var why: String?
                switch request.action {
                case .path(let path): if case .blocked(let reason) = verdict(e, path: path) { why = reason }
                case .command: why = StorageRules.entryInUse(e, running: state)
                case .dockerVolume: break
                }
                if let why {
                    message = "Not done: \(why)"
                    working.remove(request.id)
                    return
                }
            }
            message = await worker.perform(request, log: folder.appending(path: "actions.md"))
            working.remove(request.id)
            if case .dockerVolume = request.action { docker = await worker.docker(withSizes: false) }
            if request.entryID == "ios-simulators" { simulators = await worker.simulators() }
            refresh(force: true, only: request.entryID)
        }
    }

    func dismissMessage() { message = nil }
}

/// The Storage tab's background work, off the main actor.
actor StorageWorker {
    private let whatsappAnalyzer = WhatsAppAnalyzer(
        cacheURL: URL.cachesDirectory.appending(path: "com.marcos.Hawk/whatsapp.json"))

    func load(scan: URL, history: URL) -> (scan: StorageScan?, error: String?, growth: [String: Double], series: [String: [Double]]) {
        do {
            let s = try StorageScan.load(scan)
            let h = StorageHistory.load(history)
            return (s, nil, h.compactMapValues { StorageHistory.growth($0, days: 30) }, h.mapValues { Array($0.suffix(40).map(\.1)) })
        } catch {
            Log.app.warning("Could not read \(scan.path): \(error.localizedDescription)")
            return (nil, "No scan at \(scan.path). Run mac-scan once, or set the storage folder.", [:], [:])
        }
    }

    func lastTouched(_ paths: [String]) -> [String: Date] {
        var out: [String: Date] = [:]
        for p in paths where p.hasPrefix("/") { out[p] = StorageUsage.lastTouched(p) }
        return out
    }

    func running(bundleIDs: Set<String>) -> RunningState {
        let me = getuid()
        return RunningState(bundleIDs: bundleIDs, commandLines: listProcesses().filter { $0.uid == me }.compactMap { commandLine($0.pid) })
    }

    func docker(withSizes: Bool) -> DockerState { Docker.state(withSizes: withSizes) }

    func simulators() -> [SimulatorDevice] { Xcode.simulators() }

    func derivedData(_ paths: [String]) -> [String: (project: String?, lastOpened: Date?)] {
        Dictionary(uniqueKeysWithValues: paths.map { ($0, Xcode.derivedDataInfo($0)) })
    }

    func whatsappCached() -> WhatsAppReport? { whatsappAnalyzer.cached() }
    func whatsapp() -> Result<WhatsAppReport?, WhatsAppAnalyzer.Failure> {
        do { return .success(try whatsappAnalyzer.analyze()) } catch { return .failure(.noAccess) }
    }

    /// mac-scan through a login shell, so it sees the same PATH (docker, xcrun) as in Terminal.
    func runScanner(_ scanner: URL, force: Bool, only: String?) -> Bool {
        var args = ["--quiet"]
        if force { args.append("--force") }
        if let only { args += ["--only", only] }
        let line = ([scanner.path] + args).map(Self.quote).joined(separator: " ")
        let r = runCommand("/bin/zsh", ["-lc", line], timeout: 900)
        if r?.status != 0 { Log.app.warning("mac-scan failed: \(r?.output.suffix(300) ?? "did not start or timed out")") }
        return r?.status == 0
    }

    func perform(_ request: DeletionRequest, log: URL) -> String {
        let before = freeBytes()
        var what: String
        var failure: String?
        switch request.action {
        case .path(let path):
            what = "`rm -rf \(path)`"
            do { try FileManager.default.removeItem(atPath: path) } catch { failure = error.localizedDescription }
        case .command(let command):
            what = "`\(command)`"
            let r = runCommand("/bin/zsh", ["-lc", command], timeout: 1800)
            if r?.status != 0 { failure = r.map { String($0.output.suffix(300)) } ?? "did not finish" }
        case .dockerVolume(let name):
            what = "`docker volume rm \(name)`"
            if let docker = Docker.executable {
                let r = runCommand(docker, ["volume", "rm", name], timeout: 60)
                if r?.status != 0 { failure = r.map { String($0.output.suffix(300)) } ?? "did not finish" }
            } else { failure = "docker not found" }
        }
        let after = freeBytes()
        let gained = Double(after - before) / 1e9
        let line = String(format: "- %@ (%@): free %.2f → %.2f GB (%+.2f)%@\n", what, request.entryName,
                          Double(before) / 1e9, Double(after) / 1e9, gained, failure.map { " — FAILED: \($0)" } ?? "")
        append(to: log, line: line)
        if let failure {
            Log.app.error("Storage action failed: \(what): \(failure)")
            return "Failed: \(failure)"
        }
        Log.app.info("Storage action: \(what), \(String(format: "%+.2f", gained)) GB")
        return String(format: "Done: %.2f GB freed (%@)", gained, request.entryName)
    }

    /// Appends to the storage folder's actions log, under one heading per day.
    private func append(to log: URL, line: String) {
        let day = Date().formatted(.iso8601.year().month().day())
        let heading = "## \(day) (approved in Hawk)"
        let existing = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let text = (existing.contains(heading) ? "" : "\n\(heading)\n") + line
        do {
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            Log.app.error("Could not append to \(log.path): \(error.localizedDescription)")
        }
    }

    private func freeBytes() -> Int64 {
        var s = statfs()
        guard statfs(NSHomeDirectory(), &s) == 0 else { return 0 }
        return Int64(s.f_bavail) * Int64(s.f_bsize)
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
