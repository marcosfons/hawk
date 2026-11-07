//
//  RootView.swift
//  Hawk
//
//  Header with the numbers that matter most, then the fan card across the full
//  width and the rest in a grid that reflows from one to several columns as the
//  window is resized.
//

import HawkKit
import SwiftUI

struct RootView: View {
    @Environment(Monitor.self) private var monitor
    /// Measured once per resize; layouts choose from it instead of ViewThatFits,
    /// which would measure every alternative on each update.
    @State private var width: CGFloat = 1000

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(width: width)
            switch monitor.tab {
            case .cpu: ProcessesView(kind: .cpu)
            case .memory: ProcessesView(kind: .memory)
            case .energy: EnergyView()
            case .network: NetworkView()
            case .storage: StorageView(wide: width >= 1000)
            case .overview: overview
            }
        }
        .background(Palette.background)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task { monitor.start() }
    }

    /// Nothing until the first sample (a fraction of a second), rather than a spinner
    /// that would flash and then jump to the cards.
    @ViewBuilder private var overview: some View {
            if monitor.hasData {
                ScrollView {
                    VStack(spacing: Metrics.spacing) {
                        FanCard(wide: width >= 900)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.minCardWidth), spacing: Metrics.spacing, alignment: .top)],
                                  spacing: Metrics.spacing) {
                            CPUCard()
                            TemperatureCard()
                            GPUCard()
                            MemoryCard()
                            PowerCard()
                            DiskCard()
                            NetworkCard()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .scrollIndicators(.automatic)
            } else {
                Color.clear
            }
    }
}

/// The always-visible summary. Chips drop out from the least important end when
/// the window gets narrow.
struct HeaderBar: View {
    let width: CGFloat
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        let s = monitor.snapshot
        HStack(spacing: 10) {
            Picker("View", selection: $monitor.tab) {
                // Icons only when the window is too narrow for six labelled tabs.
                ForEach(Tab.allCases) { tab in
                    if width < 1300 {
                        Image(systemName: tab.symbol).accessibilityLabel(tab.rawValue).tag(tab)
                    } else {
                        Label(tab.rawValue, systemImage: tab.symbol).tag(tab)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            chips(s, count: min(max(Int((width - (width < 1300 ? 560 : 900)) / 105), 0), 7))
            Spacer(minLength: 0)
            // No .help() anywhere in the header or the Overview: a tooltip makes SwiftUI
            // re-hit-test the whole window after every update, which cost more than the update.
            Text("Hawk \(String(format: "%.1f%%", monitor.selfCPU * 100)) - \(Format.bytes(Double(monitor.selfMemory)))")
                .font(Typography.caption).foregroundStyle(Palette.tertiary)
                .frame(width: 104, alignment: .trailing)
            AlertsButton()
            Picker("Sample every", selection: $monitor.interval) {
                ForEach(SampleInterval.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            Picker("Chart range", selection: $monitor.range) {
                ForEach(ChartRange.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.leading, Metrics.titleBarInset)
        .padding(.trailing, 16)
        .padding(.vertical, 10)
    }

    private func chips(_ s: Snapshot, count: Int) -> some View {
        let fanRPM = s.fans.map(\.actual).max() ?? 0
        let all: [(String, String, String, Color)] = [
            ("thermometer.medium", Format.celsius(s.socMax), "SoC", Palette.heat(s.socMax)),
            ("fanblades.fill", fanRPM < 1 ? "Off" : Format.rpm(fanRPM), "Fans", Palette.accent),
            ("cpu", Format.percent(s.cpuTotal), "CPU", Palette.load(s.cpuTotal)),
            ("bolt.fill", Format.watts(s.systemPower), "Power", Palette.power),
            ("battery.75percent", s.power.map { "\($0.percent)%" } ?? "-",
             s.power.map { ChargeStatus.describe($0, batteryTemp: nil).title.hasPrefix("Holding") ? "Held" : $0.isCharging ? "Charging" : "Battery" } ?? "Battery",
             Palette.battery),
            ("square.stack.3d.up.fill", Format.percent(s.gpu ?? 0), "GPU", Palette.gpu),
            ("memorychip", s.memory.map { Format.percent($0.pressure) } ?? "-", "Pressure", Palette.load(s.memory?.pressure ?? 0)),
        ]
        return HStack(spacing: 8) {
            ForEach(all.prefix(count), id: \.2) { symbol, value, label, color in
                HeaderChip(symbol: symbol, value: value, label: label, color: color)
            }
        }
        .fixedSize()
    }
}

struct HeaderChip: View {
    let symbol: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            Text(value).font(Typography.value)
            Text(label).font(Typography.caption).foregroundStyle(Palette.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Palette.card))
        .overlay(Capsule().strokeBorder(Palette.cardStroke))
        .accessibilityElement(children: .combine)
    }
}
