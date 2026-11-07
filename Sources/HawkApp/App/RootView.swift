//
//  RootView.swift
//  Hawk
//
//  The window: a header with the tabs and the numbers that matter most, and the
//  selected feature below it. The window's views exist only while it is open;
//  closing it frees them and Hawk carries on in the menu bar.
//

import AppKit
import HawkKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    /// Measured once per resize; layouts choose from it instead of ViewThatFits,
    /// which would measure every alternative on each update.
    @State private var width: CGFloat = 1000

    var body: some View {
        // Every feature fills the window from the top, whatever its content's own size:
        // otherwise a short view (an empty state) is centred, with the window's own grey
        // above and below. The header sits in the title bar row, beside the traffic lights.
        VStack(spacing: 0) {
            HeaderBar(width: width)
            app.selected.makeView()
                .environment(\.contentWidth, width)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .background(Palette.background)
        .containerBackground(Palette.background, for: .window)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            app.windowAppeared()
        }
        .onDisappear {
            // No window, no Dock icon: Hawk lives in the menu bar until reopened.
            NSApp.setActivationPolicy(.accessory)
            app.windowDisappeared()
        }
    }
}

/// The always-visible summary. Chips drop out from the least important end when
/// the window gets narrow, and tabs lose their titles before that.
struct HeaderBar: View {
    let width: CGFloat
    @Environment(AppModel.self) private var app
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var app = app
        @Bindable var monitor = monitor
        let iconsOnly = width < 1550
        let tabsWidth: CGFloat = iconsOnly ? CGFloat(app.features.count) * 38 : CGFloat(app.features.count) * 104
        HStack(spacing: 10) {
            Picker("View", selection: $app.selectedID) {
                ForEach(app.features, id: \.id) { feature in
                    if iconsOnly {
                        Image(systemName: feature.symbol).accessibilityLabel(feature.title).tag(feature.id)
                    } else {
                        Label(feature.title, systemImage: feature.symbol).tag(feature.id)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            chips(monitor.snapshot, count: min(max(Int((width - Metrics.titleBarInset - tabsWidth - 340) / 105), 0), 7))
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
        .padding(.top, 4)
        .padding(.bottom, 8)
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
