//
//  Monitor.swift
//  Hawk
//
//  The shared system data, on the main actor: the latest snapshot, its history,
//  processes, energy, network, alerts, and the settings that drive them. It runs
//  the Engine on a timer from launch to quit, window or not, because fan
//  control, alerts and energy totals must keep working in the menu bar.
//
//  What it samples beyond the basics follows `needs` (set by AppModel from the
//  visible features). While nothing shows its data (`publishing` false) it keeps
//  ticks back instead of updating observed state, so a closed window costs only
//  the sampling; `headline` is the one exception, for the menu bar label.
//

import HawkKit
import Foundation
import Observation

enum SampleInterval: Double, CaseIterable, Identifiable {
    case half = 0.5, one = 1, two = 2
    var id: Double { rawValue }
    var label: String { rawValue < 1 ? "0.5 s" : "\(Int(rawValue)) s" }
}

enum ChartRange: Double, CaseIterable, Identifiable {
    case oneMinute = 60, fiveMinutes = 300, tenMinutes = 600
    var id: Double { rawValue }
    var label: String { "\(Int(rawValue / 60)) min" }
}

/// The few figures the menu bar label shows, rounded so it only redraws when they change.
struct Headline: Equatable {
    var chip: Int?
    var cpu = 0
}

@Observable
final class Monitor {
    private(set) var snapshot = Snapshot()
    private(set) var control = ControlStatus()
    private(set) var history = History()
    private(set) var hasData = false
    private(set) var headline = Headline()
    /// Bytes moved on physical interfaces since the app started.
    private(set) var downloaded = 0.0
    private(set) var uploaded = 0.0
    private(set) var processes: [ProcessStat] = []
    /// Why some figures are missing from the process list, if they are.
    private(set) var processNote: String?
    private(set) var energy: [EnergyUse] = []
    private(set) var systemEnergy = 0.0
    private(set) var unpluggedAt: Date?
    private(set) var network: [NetworkProcess] = []
    /// Recent alerts, newest first; `unseenAlerts` counts those since the panel was last opened.
    private(set) var alerts: [FanAlert] = []
    private(set) var unseenAlerts = 0
    /// Hawk's own CPU (1.0 = one core) and memory, so its cost is always in view.
    private(set) var selfCPU = 0.0
    private(set) var selfMemory: UInt64 = 0

    var settings: ControlSettings { didSet { save() } }
    var interval: SampleInterval { didSet { save() } }
    var range: ChartRange { didSet { save() } }
    var energyWindow: EnergyWindow { didSet { save() } }
    var alertSettings: AlertSettings { didSet { save() } }

    /// What the visible features need sampled. Set by AppModel.
    @ObservationIgnored var needs: Set<Need> = []
    /// Whether a window or the menu bar panel shows Monitor's data. Set by AppModel.
    @ObservationIgnored var publishing = true {
        didSet { if publishing && !oldValue { catchUp() } }
    }

    @ObservationIgnored private let engine = Engine()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Ticks taken while nothing was showing; applied when something shows again.
    @ObservationIgnored private var backlog: [Tick] = []
    /// Only the newest lists matter, so the backlog does not keep one per tick.
    @ObservationIgnored private var pendingLists: Tick?
    @ObservationIgnored private let launched = Date()
    @ObservationIgnored private var busySince: Date?
    @ObservationIgnored private var lastBusyWarning = Date.distantPast

    init() {
        settings = defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(ControlSettings.self, from: $0) } ?? ControlSettings()
        interval = SampleInterval(rawValue: defaults.double(forKey: "interval")) ?? .one
        range = ChartRange(rawValue: defaults.double(forKey: "range")) ?? .fiveMinutes
        energyWindow = defaults.string(forKey: "energyWindow").flatMap(EnergyWindow.init(rawValue:)) ?? .hour
        alertSettings = defaults.data(forKey: "alerts").flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
    }

    func start() {
        guard loop == nil else { return }
        Log.app.info("Monitoring every \(interval.label), fan mode \(settings.mode.rawValue)")
        MainThreadWatchdog.shared.start()
        loop = Task {
            while !Task.isCancelled {
                let request = TickRequest(settings: settings, processes: needs.contains(.processes),
                                          energy: needs.contains(.energy), network: needs.contains(.network),
                                          energyWindow: energyWindow, alerts: alertSettings)
                apply(await engine.tick(request))
                try? await Task.sleep(for: .seconds(interval.rawValue))
            }
        }
    }

    /// Before quitting: keep the energy totals.
    func stop() async { await engine.save() }

    /// Raises an alert from outside the Engine (a feature's own checks): listed with the
    /// others and posted as a notification when those are on.
    func post(_ alert: FanAlert) {
        alerts.insert(alert, at: 0)
        alerts = Array(alerts.prefix(50))
        unseenAlerts += 1
        if alertSettings.notify { notifier.post(alert) }
    }

    func alertsSeen() { unseenAlerts = 0 }
    func clearAlerts() { alerts.removeAll(); unseenAlerts = 0 }

    var recent: [Sample] { history.window(range.rawValue) }

    private func apply(_ tick: Tick) {
        let s = tick.snapshot
        // Alerts and the menu bar headline go out whether or not anything is showing.
        for alert in tick.alerts { post(alert) }
        let headline = Headline(chip: s.socMax.map { Int($0.rounded()) }, cpu: Int((s.cpuTotal * 100).rounded()))
        if headline != self.headline { self.headline = headline }
        watchOwnCost(tick)
        guard publishing else {
            if tick.processes != nil || tick.energy != nil || tick.network != nil { pendingLists = tick }
            backlog.append(tick.slim)
            if backlog.count > History.capacity { backlog.removeFirst() }
            return
        }
        if hasData {
            let dt = s.date.timeIntervalSince(snapshot.date)
            downloaded += s.netRx * dt
            uploaded += s.netTx * dt
        } else {
            Log.app.info(String(format: "First data %.0f ms after launch", Date().timeIntervalSince(launched) * 1000))
        }
        snapshot = s
        control = tick.control
        selfCPU = tick.selfCPU
        selfMemory = tick.selfMemory
        systemEnergy = tick.systemEnergy
        unpluggedAt = tick.unpluggedAt
        applyLists(tick)
        history.append(s)
        hasData = true
    }

    private func catchUp() {
        Log.app.debug("Showing again; \(backlog.count) samples to catch up")
        let ticks = backlog
        backlog.removeAll()
        for tick in ticks { apply(tick) }
        if let lists = pendingLists { applyLists(lists) }
        pendingLists = nil
    }

    private func applyLists(_ tick: Tick) {
        if let p = tick.processes {
            processes = p
            processNote = tick.processNote
        }
        if let e = tick.energy { energy = e }
        if let n = tick.network { network = n }
    }

    /// Logs when Hawk itself gets expensive: above 10% of a core for 10 s straight.
    private func watchOwnCost(_ tick: Tick) {
        let now = tick.snapshot.date
        guard tick.selfCPU > 0.10 else { busySince = nil; return }
        let since = busySince ?? now
        busySince = since
        if now.timeIntervalSince(since) >= 10, now.timeIntervalSince(lastBusyWarning) > 300 {
            lastBusyWarning = now
            Log.app.warning(String(format: "Hawk itself used %.0f%% CPU for 10 s (needs %@, %@, last tick %.0f ms)",
                                   tick.selfCPU * 100, needs.map(\.rawValue).sorted().joined(separator: ","),
                                   publishing ? "showing" : "hidden", tick.tickMilliseconds))
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
            defaults.set(try JSONEncoder().encode(alertSettings), forKey: "alerts")
        } catch { Log.app.error("Could not save settings: \(error.localizedDescription)") }
        defaults.set(interval.rawValue, forKey: "interval")
        defaults.set(range.rawValue, forKey: "range")
        defaults.set(energyWindow.rawValue, forKey: "energyWindow")
    }
}
