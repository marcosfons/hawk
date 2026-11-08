//
//  AppsModel.swift
//  Hawk
//
//  The Apps list for one device. The shell gives the list on its own (package
//  index, installers, disabled, sizes: one batch); the on-device helper adds
//  dates, target SDK, labels and icons in one run, fetching icons only for apps
//  whose version has none cached, user apps first, 100 per run. If the helper
//  fails, the list stays as the shell gave it. Read when the section opens, never
//  periodically.
//

import AppKit
import HawkKit
import Observation

@Observable
final class AppsModel {
    private(set) var apps: [AppEntry] = []
    private(set) var shown: [AppEntry] = []
    private(set) var icons: [String: NSImage] = [:]
    private(set) var refreshing = false
    private(set) var status: String?
    var filter: AppFilter = .user { didSet { if filter != oldValue { refilter() } } }
    var query = "" { didSet { if query != oldValue { refilter(debounce: true) } } }

    @ObservationIgnored private var loadedFor: DeviceID?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private var cachedIcons: Set<String> = []

    static let file = "apps.json"
    static let iconPx = 32

    func load(_ context: SectionContext) async {
        guard loadedFor != context.device.id else { return }
        loadedFor = context.device.id
        apps = []
        shown = []
        icons = [:]
        cachedIcons = []
        status = nil
        if let kept = await context.hub.store?.load([AppEntry].self, Self.file, for: context.device.id) { setApps(kept) }
        await loadIcons(context)
    }

    func refresh(_ context: SectionContext) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let id = context.device.id
        do {
            if await context.hub.packages(for: id) == nil { await context.hub.refreshPackages(id) }
            guard let index = await context.hub.packages(for: id) else { throw AdbError.commandFailed(status: -1, stderr: "No package list") }
            let session = try await context.hub.session(for: id)
            var parts = AppCatalog.shellParts
            parts["diskstats"] = "dumpsys diskstats"
            let shell = try await session.shellBatch(parts, timeout: .seconds(20))
            let storage = await Task.detached(priority: .utility) { DeviceStorage.parse(["diskstats": shell["diskstats"] ?? ""]) }.value
            setApps(AppCatalog.build(index: index, shell: shell, storage: storage))
            await enrich(context, session: session, index: index, shell: shell, storage: storage)
            await context.hub.store?.save(apps, as: Self.file, for: id)
            if status?.hasPrefix("Icons") != true { status = nil }
        } catch {
            status = "Could not read the apps: \((error as? AdbError)?.summary ?? error.localizedDescription)"
        }
    }

    /// One helper run: metadata for every app, and the first batch of missing icons.
    private func enrich(_ context: SectionContext, session: any DeviceSession, index: PackageIndex,
                        shell: [String: String], storage: DeviceStorage) async {
        guard let dex = HelperRunner.bundledDex() else { return Log.app.warning("Android helper missing from the app bundle") }
        let runner = HelperRunner(dex: dex, session: session)
        let batches = AppCatalog.iconBatches(apps, cached: cachedIcons)
        var commands: [HelperCommand] = [.apps]
        if let first = batches.first { commands.append(.icons(px: Self.iconPx, packages: first)) }
        do {
            let out = try await runner.run(commands, timeout: .seconds(60))
            guard out.complete || !out.apps.isEmpty else { status = "Labels and icons unavailable on this device"; return }
            await store(out.icons, context)
            let labelled = await context.hub.packages(for: context.device.id) ?? index
            setApps(AppCatalog.build(index: labelled, shell: shell, helper: out.apps, storage: storage))
            if batches.count > 1 { status = "Icons: \(batches.count - 1) more batches next time the list opens" }
        } catch {
            Log.app.warning("Android helper failed: \((error as? AdbError)?.summary ?? error.localizedDescription)")
            status = "Labels and icons unavailable: the helper did not run"
        }
    }

    private func store(_ fetched: [HelperIcon], _ context: SectionContext) async {
        var labels: [String: String] = [:]
        for icon in fetched {
            labels[icon.name] = icon.label
            let key = "\(icon.name)-\(icon.versionCode)"
            cachedIcons.insert(key)
            guard let png = icon.png else { continue }
            try? await context.hub.store?.saveBlob(png, name: "icon-\(key).png", for: context.device.id)
            if let image = NSImage(data: png) { icons[icon.name] = image }
        }
        if !labels.isEmpty { await context.hub.setLabels(labels, for: context.device.id) }
    }

    /// Icons kept for the versions installed now.
    private func loadIcons(_ context: SectionContext) async {
        guard let store = context.hub.store else { return }
        var found: [String: NSImage] = [:]
        for app in apps {
            guard let data = await store.blob(name: "icon-\(app.iconKey).png", for: context.device.id), let image = NSImage(data: data) else { continue }
            found[app.name] = image
            cachedIcons.insert(app.iconKey)
        }
        icons = found
    }

    func perform(_ action: AndroidAction, app: AppEntry, context: SectionContext) async {
        do {
            let session = try await context.hub.session(for: context.device.id)
            let result = await AppActions.perform(action, isSystem: app.isSystem, on: session, deviceName: context.device.name, store: context.hub.store)
            switch result {
            case .done: status = "\(action.name): \(app.title) - done"
            case .failed(let why): status = "\(action.name) failed: \(why)"
            case .blocked(let why): status = "\(action.name) not allowed: \(why)"
            }
            if result == .done, action != .forceStop(package: app.name) {
                await context.hub.refreshPackages(context.device.id)
                await refresh(context)
            }
        } catch {
            status = "\(action.name) failed: \((error as? AdbError)?.summary ?? error.localizedDescription)"
        }
    }

    private func setApps(_ new: [AppEntry]) {
        guard new != apps else { return }
        apps = new
        refilter()
    }

    /// Filtering runs off the main actor; typing waits 150 ms for a pause.
    private func refilter(debounce: Bool = false) {
        filterTask?.cancel()
        let all = apps, filter = filter, query = query
        filterTask = Task { [weak self] in
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) { AppCatalog.filter(all, filter, query: query) }.value
            guard !Task.isCancelled, let self else { return }
            if result != self.shown { self.shown = result }
        }
    }
}
