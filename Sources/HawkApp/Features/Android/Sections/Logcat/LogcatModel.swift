//
//  LogcatModel.swift
//  Hawk
//
//  The Logcat page's state for one device. A LogcatEngine (HawkKit, an actor)
//  does the streaming, parsing, classifying and filtering; this model only
//  applies its deltas, at most four a second, and keeps the filter text.
//

import AppKit
import HawkKit
import Observation

@Observable
final class LogcatModel {
    private(set) var rows: [LogEntry] = []
    private(set) var version = 0
    private(set) var total = 0
    private(set) var running = false
    private(set) var ended: String?
    private(set) var filter = LogFilter()
    private(set) var invalid: [String] = []
    var selected: LogEntry?
    var paused = false { didSet { if paused != oldValue { let p = paused; Task { await engine?.setPaused(p) } } } }
    var filterText = "" { didSet { if filterText != oldValue { scheduleFilter() } } }

    @ObservationIgnored private var engine: LogcatEngine?
    @ObservationIgnored private var filterTask: Task<Void, Never>?
    @ObservationIgnored private(set) var appNames: [Int: String] = [:]
    @ObservationIgnored private(set) var packages: [(name: String, title: String)] = []
    @ObservationIgnored private var context = LogFilter.Context()

    /// Streams until the task running it is cancelled (the page closes, the window
    /// hides, the device goes): then the phone's logcat stops too.
    func run(_ section: SectionContext) async {
        await loadPackages(section)
        guard let session = try? await section.hub.session(for: section.device.id) else { return }
        let engine = LogcatEngine()
        self.engine = engine
        await engine.setContext(context)
        await engine.setFilter(filter)
        await engine.setPaused(paused)
        await engine.start(session, keepingTailIn: section.hub.store)
        running = true
        ended = nil
        for await update in engine.updates {
            apply(update)
            if update.ended != nil { break }
        }
        await engine.stop()
        running = false
    }

    func clear() { Task { await engine?.clear() } }

    /// The visible (filtered) lines as text, the way logcat prints them.
    func exportText() async -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return await visible().map { e in
            "\(f.string(from: Date(timeIntervalSince1970: e.time))) \(e.uid.map(String.init) ?? "-") \(e.pid) \(e.tid) \(e.level.letter) \(e.tag): \(e.message)"
        }.joined(separator: "\n") + "\n"
    }

    /// A chip was clicked: the filter changes and so does the bar's text.
    func setFilter(_ f: LogFilter) {
        filterTask?.cancel()
        filter = f
        invalid = f.invalid
        if filterText != f.text { filterText = f.text }
        filterTask?.cancel()
        Task { await engine?.setFilter(f) }
    }

    func visible() async -> [LogEntry] { await engine?.visible() ?? rows }

    func appName(_ e: LogEntry) -> (name: String, color: NSColor?) {
        guard let uid = e.uid, uid >= 10_000, let name = appNames[uid % 100_000] else { return ("", nil) }
        return (name, Palette.logApps[abs(name.hashValue) % Palette.logApps.count])
    }

    private func apply(_ u: LogcatEngine.Update) {
        if u.reset {
            rows = u.lines
        } else {
            if u.dropped > 0 { rows.removeFirst(min(u.dropped, rows.count)) }
            rows.append(contentsOf: u.lines)
        }
        total = u.total
        if let e = u.ended { ended = e }
        version &+= 1
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        let text = filterText
        filterTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            let f = LogFilter(parsing: text)
            self.filter = f
            self.invalid = f.invalid
            await self.engine?.setFilter(f)
        }
    }

    private func loadPackages(_ section: SectionContext) async {
        guard let index = await section.hub.packages(for: section.device.id) else { return }
        var byUID: [Int: [String]] = [:]
        var names: [Int: String] = [:]
        for p in index.packages.values {
            guard let uid = p.uid else { continue }
            byUID[uid, default: []].append(p.name)
            names[uid] = p.label ?? p.name
        }
        appNames = names
        packages = index.packages.values.filter { !$0.isSystem }.map { ($0.name, $0.label ?? $0.name) }.sorted { $0.title < $1.title }
        context.uidPackages = byUID
        await engine?.setContext(context)
    }
}
