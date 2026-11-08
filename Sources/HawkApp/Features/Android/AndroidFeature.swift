//
//  AndroidFeature.swift
//  Hawk
//
//  The Android tab: devices on the left (live and disconnected), then the
//  sections; the selected section on the right. All device work goes through
//  `AndroidHub` (HawkKit), which lives for the whole app: with the tab closed it
//  keeps only the idle device watch. Sections do their own periodic work only
//  while they are shown (the Overview's one batch every 3 s).
//

import HawkKit
import Observation
import SwiftUI

@Observable
final class AndroidFeature: Feature {
    let id = "android"
    let title = "Android"
    let symbol = "candybarphone"

    private(set) var snapshot = AndroidHub.Snapshot()
    var selectedDevice: DeviceID? {
        didSet {
            guard selectedDevice != oldValue else { return }
            defaults.set(selectedDevice?.rawValue, forKey: "androidDevice")
            overview.device = selectedDevice
            updateVisibility()
        }
    }
    var section: AndroidSection {
        didSet {
            guard section != oldValue else { return }
            defaults.set(section.rawValue, forKey: "androidSection")
            updateVisibility()
        }
    }

    @ObservationIgnored let hub = AndroidHub()
    /// Catches ANRs and crashes from the DropBox, window open or not (plan C).
    @ObservationIgnored let crashes: CrashWatcher
    /// Devices usable at the last snapshot: the crash watcher follows them (plan C),
    /// and one that becomes usable again gets its forced power states undone (plan D).
    @ObservationIgnored private var liveIDs: Set<DeviceID> = []
    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored let overview: OverviewModel
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// The tab is on screen (window open and visible); sections stop their work otherwise.
    private(set) var visible = false

    init(monitor: Monitor) {
        self.monitor = monitor
        let hub = hub
        overview = OverviewModel(hub: hub)
        crashes = CrashWatcher(hub: hub)
        let crashes = crashes
        Task {
            for await alert in crashes.alerts {
                let r = alert.record
                let app = r.package ?? r.process ?? "an app"
                monitor.post(FanAlert(key: "android-\(r.kind.rawValue)-\(r.key)", title: "\(r.kind.title) on \(alert.deviceName): \(app)",
                                      body: r.reason, date: r.date, kind: r.kind == .anr ? .androidANR : .androidCrash))
            }
        }
        section = UserDefaults.standard.string(forKey: "androidSection").flatMap(AndroidSection.init) ?? .overview
        selectedDevice = UserDefaults.standard.string(forKey: "androidDevice").map(DeviceID.init)
        overview.device = selectedDevice
        Task { [weak self] in
            await hub.start()
            for await snapshot in hub.snapshots {
                guard let self else { return }
                self.received(snapshot)
            }
        }
    }

    func makeView() -> AnyView { AnyView(AndroidView(feature: self)) }

    func setVisible(_ visible: Bool) {
        if self.visible != visible { self.visible = visible }
        Task { await hub.setTabVisible(visible) }
        updateVisibility()
    }

    var device: Device? { snapshot.devices.first { $0.id == selectedDevice } }

    func startAdb() { Task { await hub.server.userStart() } }
    func stopAdb() { Task { await hub.server.userStop() } }
    func restartAdb() { Task { await hub.server.userRestart() } }

    func rename(_ id: DeviceID, to name: String) { Task { await hub.setNickname(name, for: id) } }

    func forget(_ id: DeviceID) {
        Task {
            await hub.forget(id)
            if selectedDevice == id { selectedDevice = nil }
        }
    }

    private func received(_ new: AndroidHub.Snapshot) {
        guard new != snapshot else { return }
        snapshot = new
        // Default to the first live device, or the first known one.
        if selectedDevice == nil || !new.devices.contains(where: { $0.id == selectedDevice }) {
            selectedDevice = new.devices.first(where: \.isConnected)?.id ?? new.devices.first?.id
        }
        overview.deviceChanged(device)
        let live = Set(new.devices.filter { $0.state == .device }.map(\.id))
        for id in live.subtracting(liveIDs) {
            let hub = hub, name = new.devices.first { $0.id == id }?.name ?? "Device"
            Task {
                guard let session = try? await hub.session(for: id) else { return }
                await PowerForces.undoAll(on: session, deviceName: name, store: hub.store)
                await SavedTunnels.restore(on: session, store: hub.store)
                // A capture that did not stop cleanly (unplug, crash) leaves the phone's
                // proxy pointing at Hawk: put the phone's own back (plan F3).
                await ProxyRestore.restoreIfNeeded(on: session, deviceName: name, store: hub.store)
            }
        }
        // A device that drops while the server runs raises an alert (a user stop does not).
        if case .running = new.server.state {
            for id in liveIDs.subtracting(live) {
                let name = new.devices.first { $0.id == id }?.name ?? "A device"
                monitor.post(FanAlert(key: "android-gone-\(id.rawValue)-\(Int(Date().timeIntervalSince1970))", title: "\(name) disconnected",
                                      body: "It dropped off adb. Hawk keeps its data and picks it up again when it is back.", kind: .androidDevice))
            }
        }
        if live != liveIDs {
            liveIDs = live
            let devices = new.devices, crashes = crashes
            Task { await crashes.setLive(devices) }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        overview.setVisible(visible && section == .overview && device?.isConnected == true)
    }
}
