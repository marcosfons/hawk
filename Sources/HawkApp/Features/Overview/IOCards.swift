//
//  IOCards.swift
//  Hawk
//
//  Power and battery, disk, and network.
//

import HawkKit
import SwiftUI

struct PowerCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        Card(title: "Power & Battery", symbol: "bolt.fill") {
            Text(Format.watts(s.systemPower)).font(Typography.large).foregroundStyle(Palette.power)
        } content: {
            if let p = s.power {
                HStack(alignment: .top, spacing: 16) {
                    ArcGauge(value: Double(p.percent) / 100, gradient: Palette.chargeGradient) {
                        VStack(spacing: 0) {
                            if p.isCharging || p.onAC {
                                Image(systemName: p.isCharging ? "bolt.fill" : "powerplug.fill")
                                    .font(.system(size: 12)).foregroundStyle(Palette.battery)
                            }
                            Text("\(p.percent)%").font(Typography.large)
                        }
                    }
                    .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 5) {
                        ChargeLabel(power: p, batteryTemp: s.batteryTemp)
                        LegendValue(color: Palette.battery, label: p.amperage >= 0 ? "Into battery" : "From battery",
                                    value: Format.watts(abs(p.batteryPower)))
                        LegendValue(color: Palette.battery.opacity(0.5), label: "Temperature",
                                    value: Format.celsius(s.batteryTemp), valueColor: Palette.heat(s.batteryTemp))
                        LegendValue(color: Palette.good, label: "Health",
                                    value: "\(Format.percent(p.health)) - \(p.cycles) cycles")
                    }
                }
                ChargerRow(power: p)
            }
            HistoryChart(series: [ChartSeries("Whole Mac", Palette.power, monitor.recent) { $0.power }],
                         range: monitor.range.rawValue,
                         yDomain: HistoryChart.domain([ChartSeries("Whole Mac", Palette.power, monitor.recent) { $0.power }], floor: 20),
                         fill: true, height: 70) { "\(Int($0)) W" }
        }
    }
}

private struct ChargerRow: View {
    let power: PowerInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: power.adapterName == nil ? "powerplug" : "powerplug.fill")
                .foregroundStyle(power.adapterName == nil ? Palette.tertiary : Palette.battery)
            if let name = power.adapterName {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(Typography.label).lineLimit(1)
                    Text(String(format: "%d W negotiated - %.0f V × %.2f A - drawing %@",
                                power.adapterWatts, power.adapterVolts, power.adapterAmps, Format.watts(power.adapterIn)))
                        .font(Typography.caption).foregroundStyle(Palette.secondary)
                }
            } else {
                Text("No charger connected").font(Typography.label).foregroundStyle(Palette.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.track.opacity(0.6)))
    }
}

struct DiskCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let recent = monitor.recent
        let series = [ChartSeries("Read", Palette.diskRead, recent) { $0.read },
                      ChartSeries("Write", Palette.diskWrite, recent) { $0.write }]
        Card(title: "Disk", symbol: "internaldrive.fill") {
            ForEach(s.volumes) { v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(v.name).font(Typography.label)
                        Spacer()
                        Text("\(Format.bytes(Double(v.available))) free of \(Format.bytes(Double(v.total)))")
                            .font(Typography.small).foregroundStyle(Palette.secondary)
                    }
                    MeterBar(value: v.used, color: Palette.load(v.used), height: 8)
                }
            }
            HStack(spacing: 20) {
                BigStat(value: Format.rate(s.diskRead), caption: "Read", color: Palette.diskRead, font: Typography.value)
                BigStat(value: Format.rate(s.diskWrite), caption: "Write", color: Palette.diskWrite, font: Typography.value)
            }
            HistoryChart(series: series, range: monitor.range.rawValue,
                         yDomain: HistoryChart.domain(series, floor: 1_000_000), height: 80) { Format.rate($0) }
        }
    }
}

struct NetworkCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let recent = monitor.recent
        let series = [ChartSeries("Download", Palette.download, recent) { $0.rx },
                      ChartSeries("Upload", Palette.upload, recent) { $0.tx }]
        let active = s.interfaces.filter { $0.rx + $0.tx > 0 }.map(\.name)
        Card(title: "Network", symbol: "network") {
            if !active.isEmpty {
                Text(active.joined(separator: " ")).font(Typography.caption).foregroundStyle(Palette.tertiary)
            }
        } content: {
            HStack(spacing: 20) {
                BigStat(value: Format.rate(s.netRx), caption: "Download", color: Palette.download)
                BigStat(value: Format.rate(s.netTx), caption: "Upload", color: Palette.upload)
            }
            HistoryChart(series: series, range: monitor.range.rawValue,
                         yDomain: HistoryChart.domain(series, floor: 100_000), fill: true, height: 80) { Format.rate($0) }
            Text("Since Hawk opened: \(Format.bytes(monitor.downloaded)) down - \(Format.bytes(monitor.uploaded)) up")
                .font(Typography.caption).foregroundStyle(Palette.secondary)
        }
    }
}
