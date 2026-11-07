//
//  EnergyView.swift
//  Hawk
//
//  What is draining the battery: energy per app over a window, its share of the
//  whole Mac, its draw right now, and the battery time quitting it would give
//  back. Plus what the charger is doing.
//

import AppKit
import HawkKit
import SwiftUI

nonisolated struct EnergyRow: Identifiable, Sendable {
    let id: String
    let path: String?
    let joules: Double
    let share: Double
    let watts: Double
    let gainMinutes: Double     // -1 when not meaningful
    let processes: Int
}

final class EnergyFeature: Feature {
    let id = "energy"
    let title = "Energy"
    let symbol = "bolt.fill"
    var needs: Set<Need> { [.processes, .energy] }

    func makeView() -> AnyView { AnyView(EnergyView()) }
}

private struct EnergyView: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        let s = monitor.snapshot
        let system = s.systemPower ?? 0
        let total = max(monitor.systemEnergy, monitor.energy.map(\.joules).reduce(0, +), 1)
        let rows = monitor.energy.map { e in
            EnergyRow(id: e.id, path: e.path, joules: e.joules, share: e.joules / total, watts: e.watts,
                      gainMinutes: s.power.flatMap { BatteryEstimate.gain($0, systemWatts: system, appWatts: e.watts) } ?? -1,
                      processes: e.processes)
        }
        VStack(spacing: 10) {
            EnergySummary()
            HStack(spacing: 12) {
                Picker("Window", selection: $monitor.energyWindow) {
                    ForEach(EnergyWindow.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(String(format: "Whole Mac: %.1f Wh in this window", monitor.systemEnergy / 3600))
                    .font(Typography.small).foregroundStyle(Palette.secondary)
                Spacer()
                if let note = monitor.processNote {
                    Label(note, systemImage: "lock.shield").font(Typography.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                }
            }
            if monitor.energyWindow == .sinceUnplugged && monitor.unpluggedAt == nil {
                ContentUnavailableView("On the charger", systemImage: "powerplug.fill",
                                       description: Text("This window starts counting when you unplug."))
            } else {
                DataTable(columns: Self.columns, rows: rows, sortKey: "energy").tableCard()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

extension EnergyView {
    static let columns: [Column<EnergyRow>] = [
        Column(id: "app", title: "App", width: 280, flexible: true, numeric: false, text: \.id,
               icon: { IconCache.shared.icon(forExecutable: $0.path) ?? IconCache.daemon },
               less: { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }),
        Column(id: "energy", title: "Energy", width: 80, text: { String(format: "%.2f Wh", $0.joules / 3600) }, less: { $0.joules < $1.joules }),
        Column(id: "share", title: "Share", width: 60, text: { Format.percent($0.share) }, less: { $0.share < $1.share }),
        Column(id: "now", title: "Now", width: 70, text: { String(format: "%.2f W", $0.watts) }, less: { $0.watts < $1.watts }),
        Column(id: "gain", title: "If quit", width: 72, text: { $0.gainMinutes >= 1 ? "+\(Int($0.gainMinutes)) min" : "-" },
               color: { $0.gainMinutes >= 15 ? NSColor(Palette.good) : .secondaryLabelColor }, less: { $0.gainMinutes < $1.gainMinutes }),
        Column(id: "processes", title: "Processes", width: 72, text: { "\($0.processes)" },
               color: { _ in .secondaryLabelColor }, less: { $0.processes < $1.processes }),
    ]
}

private struct EnergySummary: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        HStack(alignment: .top, spacing: Metrics.spacing) {
            Card(title: "Charging", symbol: "powerplug.fill") {
                if let p = s.power { ChargeLabel(power: p, batteryTemp: s.batteryTemp) }
            }
            Card(title: "Battery", symbol: "battery.75percent") {
                if let p = s.power {
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        BigStat(value: "\(p.percent)%", caption: String(format: "%.0f Wh left", BatteryEstimate.wattHoursLeft(p)))
                        if !p.onAC, let m = BatteryEstimate.minutes(p, watts: s.systemPower ?? 0) {
                            BigStat(value: Format.minutes(Int(m)), caption: "at the current draw", color: Palette.good)
                        } else {
                            BigStat(value: "-", caption: "estimates start on battery", color: Palette.secondary)
                        }
                    }
                }
            }
            Card(title: "Whole Mac", symbol: "bolt.fill") {
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    BigStat(value: Format.watts(s.systemPower), caption: "now", color: Palette.power)
                    BigStat(value: monitor.unpluggedAt.map { Format.ago($0).replacingOccurrences(of: " ago", with: "") } ?? "-",
                            caption: "on battery", color: Palette.secondary)
                }
            }
        }
    }
}

/// What the charger is doing, in one line, coloured by how good it is for the battery.
struct ChargeLabel: View {
    let power: PowerInfo
    let batteryTemp: Double?

    var body: some View {
        let status = ChargeStatus.describe(power, batteryTemp: batteryTemp)
        VStack(alignment: .leading, spacing: 2) {
            Text(status.title).font(Typography.value)
                .foregroundStyle(status.level == .warn ? Palette.warn : status.level == .good ? Palette.good : .white)
            if !status.detail.isEmpty {
                Text(status.detail).font(Typography.caption).foregroundStyle(Palette.secondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
