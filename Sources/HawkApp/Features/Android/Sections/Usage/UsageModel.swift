//
//  UsageModel.swift
//  Hawk
//
//  Usage per app for one device. Battery (since the last charge) and memory (now)
//  come from two shell dumps, read when the section opens and every 5 minutes while
//  it is shown (they are heavy: about 0.3 s of phone CPU together). Data per app
//  comes from the helper's history, fetched once per opening for the days missing
//  since the last fetch (100 days the first time), kept in the device folder so it
//  grows past the phone's own history. Without the helper, data falls back to
//  batterystats' totals since the charge.
//

import HawkKit
import Observation
import SwiftUI

@Observable
final class UsageModel {
    private(set) var rows: [UsageRow] = []
    private(set) var refreshing = false
    private(set) var status: String?
    private(set) var dataSinceCharge = false
    private(set) var updated: Date?
    var period: UsagePeriod = .today { didSet { if period != oldValue { rebuild() } } }

    @ObservationIgnored private var history: UsageHistory?
    @ObservationIgnored private var battery: BatteryCheckin?
    @ObservationIgnored private var memory: [String: Int64] = [:]
    @ObservationIgnored private var index: PackageIndex?
    @ObservationIgnored private var loadedFor: DeviceID?
    @ObservationIgnored private var historyFetched = false

    static let historyFile = "usage.json"

    func load(_ context: SectionContext) async {
        guard loadedFor != context.device.id else { return }
        loadedFor = context.device.id
        history = await context.hub.store?.load(UsageHistory.self, Self.historyFile, for: context.device.id)
        battery = nil
        memory = [:]
        historyFetched = false
        index = await context.hub.packages(for: context.device.id)
        rebuild()
    }

    func refresh(_ context: SectionContext) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let id = context.device.id
        do {
            let session = try await context.hub.session(for: id)
            let parts = try await session.shellBatch(["battery": BatteryCheckin.command, "memory": Meminfo.command], timeout: .seconds(30))
            let (b, m) = await Task.detached(priority: .utility) {
                (BatteryCheckin.parse(parts["battery"] ?? ""), Meminfo.parse(parts["memory"] ?? ""))
            }.value
            battery = b
            memory = m
            index = await context.hub.packages(for: id)
            if !historyFetched { await fetchHistory(context, session: session) }
            updated = Date()
            rebuild()
        } catch {
            status = "Could not read usage: \((error as? AdbError)?.summary ?? error.localizedDescription)"
        }
    }

    private func fetchHistory(_ context: SectionContext, session: any DeviceSession) async {
        historyFetched = true
        guard let dex = HelperRunner.bundledDex() else { return }
        var h = history ?? UsageHistory()
        let now = Date()
        let command = h.nextFetch(now: now)
        do {
            let out = try await HelperRunner(dex: dex, session: session).run([command], timeout: .seconds(60))
            guard out.complete else { status = "Data history incomplete: the helper stopped early"; return }
            let records = out.net, base = h
            h = await Task.detached(priority: .utility) {
                var merged = base
                merged.merge(records, fetched: command, now: now)
                return merged
            }.value
            history = h
            await context.hub.store?.save(h, as: Self.historyFile, for: context.device.id)
            status = nil
        } catch {
            Log.app.warning("Android usage history unavailable: \((error as? AdbError)?.summary ?? error.localizedDescription)")
            status = "Data per app is since the last charge: the helper did not run"
        }
    }

    private func rebuild() {
        let new = UsageTable.rows(index: index, history: history, battery: battery, memory: memory, period: period, now: Date())
        dataSinceCharge = (history?.days.isEmpty ?? true) && battery != nil
        if new != rows { rows = new }
    }
}
