//
//  Monitor.swift
//  Hawk
//
//  The app's state on the main actor: the latest snapshot, its history, and the
//  user's settings. It drives the Engine on a timer and applies what comes back;
//  views read from here and write only settings.
//

import AppKit
import HawkKit
import Foundation
import Observation

enum SampleInterval: Double, CaseIterable, Identifiable {
    case half = 0.5, one = 1, two = 2
    var id: Double { rawValue }
    var label: String { rawValue < 1 ? "0.5 s" : "\(Int(rawValue)) s" }
}

enum Tab: String, CaseIterable, Identifiable {
    case overview = "Overview", cpu = "CPU", memory = "Memory", energy = "Energy", network = "Network", storage = "Storage"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .energy: "bolt.fill"
        case .network: "network"
        case .storage: "internaldrive"
        }
    }
}

enum ChartRange: Double, CaseIterable, Identifiable {
    case oneMinute = 60, fiveMinutes = 300, tenMinutes = 600
    var id: Double { rawValue }
    var label: String { "\(Int(rawValue / 60)) min" }
}

@Observable
final class Monitor {
    private(set) var snapshot = Snapshot()
    private(set) var control = ControlStatus()
    private(set) var history = History()
    private(set) var hasData = false
    /// Bytes moved on physical interfaces since the app started.
    private(set) var downloaded = 0.0
    private(set) var uploaded = 0.0
    private(set) var processes: [ProcessStat] = []
    /// Why some figures are missing from the process list, if they are.
    private(set) var processNote: String?
    var processSearch = ""
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
    var tab: Tab { didSet { save() } }

    var settings: ControlSettings { didSet { save() } }
    var interval: SampleInterval { didSet { save() } }
    var range: ChartRange { didSet { save() } }
    var energyWindow: EnergyWindow { didSet { save() } }
    var alertSettings: AlertSettings { didSet { save() } }

    @ObservationIgnored private let engine = Engine()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Samples taken while the window was hidden. Views are not updated for them
    /// until it shows again, so a hidden window costs only the sampling.
    @ObservationIgnored private var backlog: [Tick] = []
    /// Only the newest lists matter, so the backlog does not keep one per tick.
    @ObservationIgnored private var pendingLists: Tick?
    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private let launched = Date()
    @ObservationIgnored private var busySince: Date?
    @ObservationIgnored private var lastBusyWarning = Date.distantPast

    init() {
        settings = defaults.data(forKey: "settings").flatMap { try? JSONDecoder().decode(ControlSettings.self, from: $0) } ?? ControlSettings()
        interval = SampleInterval(rawValue: defaults.double(forKey: "interval")) ?? .one
        range = ChartRange(rawValue: defaults.double(forKey: "range")) ?? .fiveMinutes
        tab = defaults.string(forKey: "tab").flatMap(Tab.init(rawValue:)) ?? .overview
        energyWindow = defaults.string(forKey: "energyWindow").flatMap(EnergyWindow.init(rawValue:)) ?? .hour
        alertSettings = defaults.data(forKey: "alerts").flatMap { try? JSONDecoder().decode(AlertSettings.self, from: $0) } ?? AlertSettings()
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.setWindowVisible(NSApp.windows.contains { $0.isVisible && $0.occlusionState.contains(.visible) })
            }
        }
    }

    private func setWindowVisible(_ visible: Bool) {
        guard visible != windowVisible else { return }
        windowVisible = visible
        Log.app.debug("Window \(visible ? "visible" : "hidden"); \(backlog.count) samples to catch up")
        if visible {
            for tick in backlog { apply(tick) }
            backlog.removeAll()
            if let lists = pendingLists { applyLists(lists) }
            pendingLists = nil
        }
    }

    func start() {
        guard loop == nil else { return }
        Log.app.info("Monitoring every \(interval.label), fan mode \(settings.mode.rawValue), tab \(tab.rawValue)")
        MainThreadWatchdog.shared.start()
        loop = Task {
            while !Task.isCancelled {
                let visible = windowVisible
                let request = TickRequest(settings: settings, processes: visible && (tab == .cpu || tab == .memory),
                                          energy: visible && tab == .energy, network: visible && tab == .network,
                                          energyWindow: energyWindow, alerts: alertSettings)
                apply(await engine.tick(request))
                try? await Task.sleep(for: .seconds(interval.rawValue))
            }
        }
    }

    /// Before quitting: keep the energy totals.
    func stop() async { await engine.save() }

    func alertsSeen() { unseenAlerts = 0 }
    func clearAlerts() { alerts.removeAll(); unseenAlerts = 0 }

    var recent: [Sample] { history.window(range.rawValue) }

    private func apply(_ tick: Tick) {
        let s = tick.snapshot
        // Alerts go out whether or not the window is visible.
        if !tick.alerts.isEmpty {
            alerts.insert(contentsOf: tick.alerts.reversed(), at: 0)
            alerts = Array(alerts.prefix(50))
            unseenAlerts += tick.alerts.count
            if alertSettings.notify { for a in tick.alerts { notifier.post(a) } }
        }
        watchOwnCost(tick)
        guard windowVisible else {
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
            Log.app.warning(String(format: "Hawk itself used %.0f%% CPU for 10 s (tab %@, window %@, last tick %.0f ms)",
                                   tick.selfCPU * 100, tab.rawValue, windowVisible ? "visible" : "hidden", tick.tickMilliseconds))
        }
    }

    private func save() {
        do {
            defaults.set(try JSONEncoder().encode(settings), forKey: "settings")
            defaults.set(try JSONEncoder().encode(alertSettings), forKey: "alerts")
        } catch { Log.app.error("Could not save settings: \(error.localizedDescription)") }
        defaults.set(interval.rawValue, forKey: "interval")
        defaults.set(range.rawValue, forKey: "range")
        defaults.set(tab.rawValue, forKey: "tab")
        defaults.set(energyWindow.rawValue, forKey: "energyWindow")
    }
}
