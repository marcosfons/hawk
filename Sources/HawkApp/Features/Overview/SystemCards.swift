//
//  SystemCards.swift
//  Hawk
//
//  CPU (with every core), GPU, temperatures and memory.
//

import HawkKit
import SwiftUI

struct CPUCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let recent = monitor.recent
        Card(title: "CPU", symbol: "cpu") {
            Text(Format.percent(s.cpuTotal)).font(Typography.large).foregroundStyle(Palette.load(s.cpuTotal))
        } content: {
            VStack(spacing: 6) {
                ClusterRow(label: "Efficiency", count: s.eCores, usage: s.eUsage, color: Palette.eCore)
                ClusterRow(label: "Performance", count: s.cores.count - s.eCores, usage: s.pUsage, color: Palette.pCore)
            }
            HistoryChart(series: [ChartSeries("Performance", Palette.pCore, recent) { $0.pCPU },
                                  ChartSeries("Efficiency", Palette.eCore, recent) { $0.eCPU }],
                         range: monitor.range.rawValue, yDomain: 0...1, fill: true, height: 80) { Format.percent($0) }
            CoreGrid(cores: s.cores, eCores: s.eCores)
        }
    }
}

private struct ClusterRow: View {
    let label: String
    let count: Int
    let usage: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(label) (\(count))").font(Typography.small).foregroundStyle(Palette.secondary)
                .frame(width: 112, alignment: .leading)
            MeterBar(value: usage, color: color)
            Text(Format.percent(usage)).font(Typography.small).frame(width: 36, alignment: .trailing)
        }
    }
}

/// One tile per logical core, with its own sparkline.
private struct CoreGrid: View {
    let cores: [Double]
    let eCores: Int
    @Environment(Monitor.self) private var monitor

    struct Core: Identifiable {
        let id: Int
        let name: String
        let usage: Double
        let color: Color
    }

    var body: some View {
        let tiles = cores.enumerated().map { i, u in
            i < eCores ? Core(id: i, name: "E\(i + 1)", usage: u, color: Palette.eCore)
                : Core(id: i, name: "P\(i - eCores + 1)", usage: u, color: Palette.pCore)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
            ForEach(tiles) { core in
                CoreTile(core: core, history: monitor.history.core(core.id, last: 40))
            }
        }
    }
}

private struct CoreTile: View {
    let core: CoreGrid.Core
    let history: [Double]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(core.name).font(Typography.caption).foregroundStyle(core.color)
                Spacer(minLength: 0)
                Text(Format.percent(core.usage)).font(Typography.caption)
            }
            Sparkline(values: history, color: core.color).frame(height: 22)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.track.opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Core \(core.name), \(Int(core.usage * 100)) percent")
    }
}

struct GPUCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let usage = s.gpu ?? 0
        Card(title: "GPU", symbol: "square.stack.3d.up.fill") {
            HStack(alignment: .center, spacing: 16) {
                ArcGauge(value: usage) {
                    VStack(spacing: 0) {
                        Text(Format.percent(usage)).font(Typography.large)
                        Text("in use").font(Typography.caption).foregroundStyle(Palette.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 8) {
                    LegendValue(color: Palette.gpu, label: "Temperature", value: Format.celsius(s.gpuTemp), valueColor: Palette.heat(s.gpuTemp))
                    HistoryChart(series: [ChartSeries("GPU", Palette.gpu, monitor.recent) { $0.gpu }],
                                 range: monitor.range.rawValue, yDomain: 0...1, fill: true, height: 70) { Format.percent($0) }
                }
            }
        }
    }
}

struct TemperatureCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        let recent = monitor.recent
        let series = [
            ChartSeries("SoC", Palette.soc, recent) { $0.socMax },
            ChartSeries("GPU", Palette.gpu, recent) { $0.gpuTemp },
            ChartSeries("SSD", Palette.ssd, recent) { $0.ssd },
            ChartSeries("Battery", Palette.battery, recent) { $0.battery },
        ]
        // Whole tens, so the scale only moves when a reading crosses one, not on every tick.
        let coolest: Double = min(series.map(\.minimum).filter { $0 > 0 }.min() ?? 30, 30)
        let hottest: Double = max(series.map(\.maximum).max() ?? 60, 60)
        let lo: Double = ((coolest - 2) / 10).rounded(.down) * 10
        let hi: Double = ((hottest + 2) / 10).rounded(.up) * 10
        Card(title: "Temperatures", symbol: "thermometer.medium") {
            Text(Format.celsius(s.socMax)).font(Typography.large).foregroundStyle(Palette.heat(s.socMax))
        } content: {
            Grid(horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    LegendValue(color: Palette.soc, label: "SoC hottest", value: Format.celsius(s.socMax), valueColor: Palette.heat(s.socMax))
                    LegendValue(color: Palette.soc.opacity(0.5), label: "SoC average", value: Format.celsius(s.socAvg), valueColor: Palette.heat(s.socAvg))
                }
                GridRow {
                    LegendValue(color: Palette.gpu, label: "GPU", value: Format.celsius(s.gpuTemp), valueColor: Palette.heat(s.gpuTemp))
                    LegendValue(color: Palette.ssd, label: "SSD", value: Format.celsius(s.ssdTemp), valueColor: Palette.heat(s.ssdTemp))
                }
                GridRow {
                    LegendValue(color: Palette.battery, label: "Battery", value: Format.celsius(s.batteryTemp), valueColor: Palette.heat(s.batteryTemp))
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            HistoryChart(series: series, range: monitor.range.rawValue, yDomain: max(lo, 0)...hi, height: 120) { "\(Int($0))°" }
        }
    }
}

struct MemoryCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        Card(title: "Memory", symbol: "memorychip") {
            if let m = s.memory {
                Text("\(Format.memory(m.used)) of \(Format.memory(m.total))").font(Typography.value)
            }
        } content: {
            if let m = s.memory {
                let total = Double(max(m.total, 1))
                StackedBar(segments: [
                    .init(id: "app", fraction: Double(m.app) / total, color: Palette.memApp),
                    .init(id: "wired", fraction: Double(m.wired) / total, color: Palette.memWired),
                    .init(id: "compressed", fraction: Double(m.compressed) / total, color: Palette.memCompressed),
                    .init(id: "cached", fraction: Double(m.cached) / total, color: Palette.memCached),
                ])
                Grid(horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        LegendValue(color: Palette.memApp, label: "App", value: Format.memory(m.app))
                        LegendValue(color: Palette.memWired, label: "Wired", value: Format.memory(m.wired))
                    }
                    GridRow {
                        LegendValue(color: Palette.memCompressed, label: "Compressed", value: Format.memory(m.compressed))
                        LegendValue(color: Palette.memCached, label: "Cached files", value: Format.memory(m.cached))
                    }
                }
                LabeledMeter(label: "Pressure", value: m.pressure, text: Format.percent(m.pressure), color: Palette.load(m.pressure))
                let swap = m.swapTotal > 0 ? Double(m.swapUsed) / Double(m.swapTotal) : 0
                LabeledMeter(label: "Swap", value: swap, text: "\(Format.memory(m.swapUsed)) of \(Format.memory(m.swapTotal))",
                             color: Palette.memCompressed)
                HStack(spacing: 14) {
                    Label("in \(Format.rate(s.swapInRate))", systemImage: "arrow.down.to.line")
                    Label("out \(Format.rate(s.swapOutRate))", systemImage: "arrow.up.to.line")
                }
                .font(Typography.caption).foregroundStyle(Palette.secondary)
                HistoryChart(series: [ChartSeries("Used", Palette.memApp, monitor.recent) { $0.memoryUsed },
                                      ChartSeries("Pressure", Palette.warn, monitor.recent) { $0.pressure }],
                             range: monitor.range.rawValue, yDomain: 0...1, height: 70) { Format.percent($0) }
            }
        }
    }
}

struct LabeledMeter: View {
    let label: String
    let value: Double
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Typography.small).foregroundStyle(Palette.secondary).frame(width: 64, alignment: .leading)
            MeterBar(value: value, color: color)
            Text(text).font(Typography.small).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .combine)
    }
}
