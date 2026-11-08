//
//  OverviewModel.swift
//  Hawk
//
//  The Overview's data for the selected device. Opening a known device shows the
//  snapshot Hawk kept at once; while the section is shown and the device is live,
//  the system is read once per connection and "right now" in one batch every 3 s
//  (OverviewProbe decides which parts each tick reads, to stay inside the phone's
//  CPU budget). Nothing runs while the section is hidden.
//

import HawkKit
import Observation
import SwiftUI

/// What is kept in the device's folder, to show before the device answers.
nonisolated struct OverviewSnapshot: Codable, Sendable {
    var system: SystemInfo?
    var now: RightNow
    var date: Date
}

@Observable
final class OverviewModel {
    private(set) var system: SystemInfo?
    private(set) var now = RightNow()
    private(set) var updated: Date?
    private(set) var error: String?

    var device: DeviceID? {
        didSet {
            guard device != oldValue else { return }
            system = nil
            now = RightNow()
            updated = nil
            error = nil
            tick = 0
            loadKept()
        }
    }

    @ObservationIgnored private let hub: AndroidHub
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var systemIsFresh = false
    @ObservationIgnored private var wasLive = false
    @ObservationIgnored private lazy var refresher = Refresher("android-overview", foreground: .seconds(3), background: nil) { [weak self] in
        await self?.refresh()
    }

    static let snapshotFile = "snapshot.json"

    init(hub: AndroidHub) {
        self.hub = hub
    }

    func setVisible(_ visible: Bool) {
        if refresher.visible, !visible { keep() }
        refresher.visible = visible
    }

    /// A reconnection may be a different build (an update, a flash): read the system again.
    func deviceChanged(_ device: Device?) {
        let live = device?.state == .device
        if live, !wasLive { systemIsFresh = false }
        wasLive = live
    }

    private func refresh() async {
        guard let id = device else { return }
        do {
            let session = try await hub.session(for: id)
            if !systemIsFresh {
                let parts = try await session.shellBatch(OverviewProbe.system, timeout: .seconds(10))
                let parsed = await Task.detached(priority: .utility) { OverviewProbe.parseSystem(parts) }.value
                guard id == device else { return }
                if parsed != system { system = parsed }
                systemIsFresh = true
                keep()
            }
            let parts = try await session.shellBatch(OverviewProbe.rightNow(tick: tick), timeout: .seconds(5))
            guard id == device else { return }
            tick += 1
            let merged = OverviewProbe.merge(parts, into: now)
            if merged != now { now = merged }
            updated = Date()
            if error != nil { error = nil }
        } catch {
            let text = (error as? AdbError)?.summary ?? error.localizedDescription
            if text != self.error { self.error = text }
        }
    }

    private func loadKept() {
        guard let id = device, let store = hub.store else { return }
        Task { [weak self] in
            guard let kept = await store.load(OverviewSnapshot.self, Self.snapshotFile, for: id) else { return }
            guard let self, self.device == id, self.updated == nil else { return }
            self.system = kept.system
            self.now = kept.now
            self.updated = kept.date
        }
    }

    private func keep() {
        guard let id = device, let store = hub.store, updated != nil || system != nil else { return }
        let snapshot = OverviewSnapshot(system: system, now: now, date: updated ?? Date())
        Task { await store.save(snapshot, as: Self.snapshotFile, for: id) }
    }
}
