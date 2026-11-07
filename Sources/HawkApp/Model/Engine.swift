//
//  Engine.swift
//  Hawk
//
//  Sampling, fan control, energy accounting and alerts, off the main actor. Each
//  tick reads the sensors, runs the fan policy, and samples processes and network
//  only when something needs them; the UI only ever receives the finished Tick.
//  Every step is timed: slow ones are logged as warnings (see Log.timed).
//

import HawkKit
import Foundation

/// What the UI wants from a tick.
nonisolated struct TickRequest: Sendable {
    var settings: ControlSettings
    var processes = false        // CPU or Memory tab open
    var energy = false           // Energy tab open
    var network = false          // Network tab open
    var energyWindow = EnergyWindow.hour
    var alerts = AlertSettings()
}

nonisolated struct Tick: Sendable {
    let snapshot: Snapshot
    let control: ControlStatus
    /// nil when processes were not sampled this tick.
    let processes: [ProcessStat]?
    let processNote: String?
    let energy: [EnergyUse]?
    let systemEnergy: Double         // joules in the requested window
    let unpluggedAt: Date?
    let network: [NetworkProcess]?
    let alerts: [FanAlert]
    /// Hawk's own cost: CPU (1.0 = one core) since the previous tick, and memory footprint.
    let selfCPU: Double
    let selfMemory: UInt64
    let tickMilliseconds: Double

    /// The same tick without the bulky lists, for the backlog kept while the window is hidden.
    var slim: Tick {
        Tick(snapshot: snapshot, control: control, processes: nil, processNote: nil, energy: nil, systemEnergy: systemEnergy,
             unpluggedAt: unpluggedAt, network: nil, alerts: alerts, selfCPU: selfCPU, selfMemory: selfMemory, tickMilliseconds: tickMilliseconds)
    }
}

actor Engine {
    private enum Key {
        static let gpuKeys = "gpuTempKeys"
        static let batteryHealth = "batteryHealth"
    }

    private let defaults = UserDefaults.standard
    // Lazy, so building them never runs on the main actor. Cached GPU keys and battery
    // health make the first sample fast; both are refreshed in the background below.
    private lazy var sampler = Sampler(gpuKeys: defaults.stringArray(forKey: Key.gpuKeys) ?? [],
                                       batteryHealth: defaults.object(forKey: Key.batteryHealth) as? Int)
    private lazy var processSampler = ProcessSampler()
    private lazy var energy = EnergyTracker(stateURL: URL.cachesDirectory.appending(path: "com.marcos.Hawk/energy.json"))
    private lazy var networkSampler = NetworkSampler()
    private let alertMonitor = AlertMonitor()
    private let helper = HelperClient()
    private var controller = CurveController()
    private var lastDate: Date?
    private var manual = false
    private var ticks = 0
    private var lastSelf: (Date, UInt64)?
    private var lastProcesses = Date.distantPast
    private var lastNetwork = Date.distantPast

    /// Processes are sampled every `processInterval` while a tab needs them, and every
    /// `backgroundProcessTicks` otherwise: often enough for energy totals (the counters
    /// are cumulative) and for switching tabs to show data at once.
    private static let backgroundProcessTicks = 15
    /// At most this often whatever the sampling interval: still faster than Activity
    /// Monitor's 5 s, and redrawing hundreds of figures every second was most of the
    /// CPU tab's cost.
    private static let processInterval = 1.9
    private static let networkInterval = 1.9

    func tick(_ request: TickRequest) -> Tick {
        let started = DispatchTime.now().uptimeNanoseconds
        ticks += 1
        let snapshot = Log.engine.timed("sensors", warnAbove: 120) { sampler.sample() }
        let dt = lastDate.map { snapshot.date.timeIntervalSince($0) } ?? 1
        lastDate = snapshot.date
        let control = Log.engine.timed("fan control", warnAbove: 300) { control(request.settings, snapshot, dt: min(dt, 5)) }

        var processes: [ProcessStat]?, note: String?
        let wantsProcesses = request.processes || request.energy
        if wantsProcesses ? snapshot.date.timeIntervalSince(lastProcesses) >= Self.processInterval
                          : ticks % Self.backgroundProcessTicks == 1 {
            lastProcesses = snapshot.date
            (processes, note) = Log.engine.timed("processes", warnAbove: 150) { sampleProcesses() }
            if let processes {
                energy.record(processes, systemWatts: snapshot.systemPower, onAC: snapshot.power?.onAC ?? true, now: snapshot.date)
            }
        }

        var network: [NetworkProcess]?
        if request.network, snapshot.date.timeIntervalSince(lastNetwork) >= Self.networkInterval {
            lastNetwork = snapshot.date
            network = Log.engine.timed("network by process", warnAbove: 150) { networkSampler.sample() }
        }

        let alerts = alertMonitor.evaluate(snapshot, processes: processes, appWatts: energy.current.mapValues(\.watts),
                                           settings: request.alerts, now: snapshot.date)
        if ticks == 3 { refreshCaches() }

        var selfCPU = 0.0, selfMemory: UInt64 = 0
        if let me = readCounters(getpid(), uid: getuid()) {
            if let (date, cpuTime) = lastSelf {
                selfCPU = Double(me.cpuTime &- cpuTime) / 1e9 / max(snapshot.date.timeIntervalSince(date), 0.001)
            }
            lastSelf = (snapshot.date, me.cpuTime)
            selfMemory = me.footprint
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        if ms > 250 { Log.engine.warning(String(format: "Slow: tick took %.0f ms (limit 250 ms)", ms)) }
        return Tick(snapshot: snapshot, control: control, processes: processes, processNote: note,
                    energy: request.energy ? energy.usage(request.energyWindow, now: snapshot.date) : nil,
                    systemEnergy: energy.systemJoules(request.energyWindow, now: snapshot.date), unpluggedAt: energy.unpluggedAt,
                    network: network, alerts: alerts, selfCPU: selfCPU, selfMemory: selfMemory, tickMilliseconds: ms)
    }

    /// Called when the app quits, so energy totals survive a restart.
    func save() { energy.save() }

    /// After the window is up: find the GPU sensors if they were not cached, and keep
    /// the cached battery health current.
    private func refreshCaches() {
        if defaults.stringArray(forKey: Key.gpuKeys) == nil {
            Log.engine.timed("GPU sensor discovery", warnAbove: 1000) { sampler.discoverGPUKeys() }
            defaults.set(sampler.gpuKeys, forKey: Key.gpuKeys)
            Log.engine.info("Found \(sampler.gpuKeys.count) GPU temperature sensors")
        }
        if let health = sampler.batteryHealth { defaults.set(health, forKey: Key.batteryHealth) }
    }

    private func sampleProcesses() -> ([ProcessStat], String?) {
        var privileged: [ProcessCounters] = []
        var note: String?
        if helper.connectIfNeeded(), let r = helper.send(.processes(skippingUID: getuid())) {
            if r.ok, let list = r.processes { privileged = list }
            else { note = "Reinstall the helper (sudo make install-helper) to see system processes' figures" }
        } else {
            note = "System processes show no figures without the helper (sudo make install-helper)"
        }
        return (processSampler.sample(privileged: privileged), note)
    }

    private func control(_ settings: ControlSettings, _ s: Snapshot, dt: Double) -> ControlStatus {
        var status = ControlStatus()
        let lo = s.fans.map(\.min).max() ?? 0, hi = s.fans.map(\.max).min() ?? 0
        let temps = s.curveTemps
        if settings.mode == .curve { status.level = settings.curve.level(temps) }

        let decision = ControlPolicy.decide(settings, temps: temps, onAC: s.power?.onAC ?? true,
                                            min: lo, max: hi, dt: dt, controller: &controller)
        status.note = decision.note

        if let rpm = decision.rpm {
            // Sent every tick: it doubles as the heartbeat the helper's watchdog waits for.
            if let response = helper.send(.set(rpm: rpm)) {
                if response.ok {
                    if !manual { Log.engine.info("Fans under manual control at \(Int(rpm)) rpm") }
                    status.targetRPM = rpm
                    manual = true
                } else {
                    Log.engine.warning("Helper refused \(Int(rpm)) rpm: \(response.message ?? "no reason")")
                    status.note = response.message
                    manual = response.manual
                }
            }
        } else if manual {
            if helper.send(.auto) != nil { Log.engine.info("Fans handed back to macOS") }
            manual = false
        } else if settings.mode != .auto {
            helper.connectIfNeeded()     // shows early whether control will be possible
        }
        status.helper = settings.mode == .auto && !manual ? .unused : helper.state
        return status
    }
}
