//
//  FanCard.swift
//  Hawk
//
//  Fan gauges, their history, and the controls: Auto (macOS), Curve, Fixed.
//  Controls only edit settings; the Engine applies them on its next tick.
//

import HawkKit
import SwiftUI

struct FanCard: View {
    let wide: Bool
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Card(title: "Fans", symbol: "fanblades") {
            Picker("Mode", selection: $monitor.settings.mode) {
                Text("Auto").tag(FanMode.auto)
                Text("Curve").tag(FanMode.curve)
                Text("Fixed").tag(FanMode.fixed)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        } content: {
            if wide {
                HStack(alignment: .top, spacing: 24) {
                    FanGauges().frame(width: 360)
                    Divider().overlay(Palette.cardStroke)
                    FanControls()
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    FanGauges()
                    FanControls()
                }
            }
            ControlStatusLine()
        }
    }
}

// MARK: - Gauges

private struct FanGauges: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let fans = monitor.snapshot.fans
        let recent = monitor.recent
        let colors = [Palette.fanLeft, Palette.fanRight]
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                ForEach(fans, id: \.index) { fan in
                    FanGauge(fan: fan, name: Self.name(fan.index, of: fans.count), target: monitor.control.targetRPM)
                }
            }
            let series = fans.map { fan in
                ChartSeries(Self.name(fan.index, of: fans.count), colors[fan.index % colors.count], recent) { s in
                    fan.index < s.fans.count ? s.fans[fan.index] : nil
                }
            }
            HistoryChart(series: series, range: monitor.range.rawValue,
                         yDomain: 0...(fans.map(\.max).max() ?? 8000), height: 70) { Format.rpm($0) }
        }
    }

    static func name(_ index: Int, of count: Int) -> String {
        count == 2 ? (index == 0 ? "Left" : "Right") : "Fan \(index + 1)"
    }
}

private struct FanGauge: View {
    let fan: SMC.Fan
    let name: String
    let target: Double?

    var body: some View {
        let state = fan.isManual ? "Manual" : fan.actual < 1 ? "Off" : "Auto"
        ArcGauge(value: fan.max > 0 ? fan.actual / fan.max : 0, gradient: Palette.fanGradient,
                 marker: fan.isManual ? target.map { $0 / fan.max } : nil, lineWidth: 9) {
            VStack(spacing: 2) {
                SpinningFan(rpm: fan.actual)
                Text(fan.actual < 1 ? "0" : Format.rpm(fan.actual))
                    .font(Typography.large)
                Text("rpm").font(Typography.caption).foregroundStyle(Palette.secondary)
            }
        }
        .frame(width: 140, height: 140)
        .overlay(alignment: .bottom) {
            VStack(spacing: 0) {
                Text(name).font(Typography.label)
                Text(state).font(Typography.caption).foregroundStyle(fan.isManual ? Palette.accent : Palette.secondary)
            }
            .offset(y: 14)
        }
        .padding(.bottom, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) fan, \(Int(fan.actual)) rpm, \(state)")
    }
}

// MARK: - Controls

private struct FanControls: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        VStack(alignment: .leading, spacing: 12) {
            switch monitor.settings.mode {
            case .auto:
                Text("macOS controls the fans. They stay off while the Mac is cool, which uses the least power.")
                    .font(Typography.label).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .curve:
                CurveEditor(curve: $monitor.settings.curve)
            case .fixed:
                FixedSpeed(rpm: $monitor.settings.fixedRPM, fans: monitor.snapshot.fans)
            }
            if monitor.settings.mode != .auto {
                Toggle("On battery, leave the fans to macOS", isOn: $monitor.settings.macOSOnBattery)
                    .font(Typography.label)
                HelperNotice(state: monitor.control.helper)
            }
        }
    }
}

private struct FixedSpeed: View {
    @Binding var rpm: Double
    let fans: [SMC.Fan]

    var body: some View {
        let lo = fans.map(\.min).max() ?? 2000, hi = fans.map(\.max).min() ?? 7000
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Speed").font(Typography.label).foregroundStyle(Palette.secondary)
                Spacer()
                Text("\(Format.rpm(min(max(rpm, lo), hi))) rpm").font(Typography.value)
            }
            Slider(value: Binding(get: { min(max(rpm, lo), hi) }, set: { rpm = $0 }), in: lo...hi, step: 100)
            Text("A fixed speed costs power even when the Mac is cool. Curve mode only spins the fans up when needed.")
                .font(Typography.caption).foregroundStyle(Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private enum Preset: String, CaseIterable, Identifiable {
    case quiet = "Quiet", balanced = "Balanced", cool = "Cool", custom = "Custom"
    var id: String { rawValue }
    var curve: FanCurve? {
        switch self {
        case .quiet: .quiet
        case .balanced: .balanced
        case .cool: .cool
        case .custom: nil
        }
    }
    static func matching(_ c: FanCurve) -> Preset { allCases.first { $0.curve == c } ?? .custom }
}

private struct CurveEditor: View {
    @Binding var curve: FanCurve
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 10) {
            Picker("Preset", selection: Binding(get: { Preset.matching(curve) }, set: { if let c = $0.curve { curve = c } })) {
                ForEach(Preset.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            CurveChart(threshold: curve.soc, fans: s.fans, socTemp: s.socMax)

            VStack(spacing: 4) {
                ThresholdRow(label: "SoC", color: Palette.soc, current: s.socMax, threshold: $curve.soc, range: 40...100)
                ThresholdRow(label: "SSD", color: Palette.ssd, current: s.ssdTemp, threshold: $curve.ssd, range: 35...85)
                ThresholdRow(label: "Battery", color: Palette.battery, current: s.batteryTemp, threshold: $curve.battery, range: 30...50)
            }
            if let level = monitor.control.level {
                HStack(spacing: 8) {
                    Text("Heat").font(Typography.small).foregroundStyle(Palette.secondary)
                    MeterBar(value: level, color: Palette.load(level))
                    Text(Format.percent(level)).font(Typography.small).frame(width: 36, alignment: .trailing)
                    if let driver = curve.driver(s.curveTemps) {
                        Text("from \(driver.rawValue)").font(Typography.caption).foregroundStyle(Palette.tertiary)
                    }
                }
            }
        }
    }
}

/// Fan speed against SoC temperature: off below the start, minimum at the start,
/// rising to maximum at full. The dot is where the Mac is now.
private struct CurveChart: View {
    let threshold: Threshold
    let fans: [SMC.Fan]
    let socTemp: Double?

    private static let temps = 30.0...105.0

    var body: some View {
        let lo = fans.map(\.min).max() ?? 2000, hi = fans.map(\.max).min() ?? 7000
        let now = fans.map(\.actual).max() ?? 0
        Canvas { context, size in
            let plot = CGRect(x: 0, y: 4, width: size.width - 40, height: size.height - 20)
            let t = Self.temps
            func x(_ c: Double) -> CGFloat { plot.minX + plot.width * CGFloat((c - t.lowerBound) / (t.upperBound - t.lowerBound)) }
            func y(_ r: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(r / (hi * 1.05)) }

            for c in [40.0, 60, 80, 100] {
                var grid = Path()
                grid.move(to: CGPoint(x: x(c), y: plot.minY)); grid.addLine(to: CGPoint(x: x(c), y: plot.maxY))
                context.stroke(grid, with: .color(Palette.grid), lineWidth: 0.5)
                context.draw(Text("\(Int(c))°").font(Typography.caption).foregroundStyle(Palette.tertiary),
                             at: CGPoint(x: x(c), y: size.height), anchor: .bottom)
            }
            for r in [lo, hi] {
                context.draw(Text(Format.rpm(r)).font(Typography.caption).foregroundStyle(Palette.tertiary),
                             at: CGPoint(x: size.width, y: y(r)), anchor: .trailing)
            }

            let points = [(t.lowerBound, 0.0), (threshold.start, 0), (threshold.start, lo), (threshold.full, hi), (t.upperBound, hi)]
            var line = Path()
            line.move(to: CGPoint(x: x(points[0].0), y: y(points[0].1)))
            for p in points.dropFirst() { line.addLine(to: CGPoint(x: x(p.0), y: y(p.1))) }
            var area = line
            area.addLine(to: CGPoint(x: x(t.upperBound), y: plot.maxY)); area.addLine(to: CGPoint(x: x(t.lowerBound), y: plot.maxY))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [Palette.accent.opacity(0.25), .clear]),
                                                     startPoint: CGPoint(x: 0, y: plot.minY), endPoint: CGPoint(x: 0, y: plot.maxY)))
            context.stroke(line, with: .color(Palette.accent), style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))

            if let socTemp {
                var rule = Path()
                rule.move(to: CGPoint(x: x(socTemp), y: plot.minY)); rule.addLine(to: CGPoint(x: x(socTemp), y: plot.maxY))
                context.stroke(rule, with: .color(Palette.soc.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let dot = CGPoint(x: x(socTemp), y: y(now))
                context.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(Palette.soc))
            }
        }
        .frame(height: 110)
        .accessibilityElement()
        .accessibilityLabel("Fan curve: on at \(Int(threshold.start)) degrees, full speed at \(Int(threshold.full)) degrees")
    }
}

private struct ThresholdRow: View {
    let label: String
    let color: Color
    let current: Double?
    @Binding var threshold: Threshold
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(Typography.small).frame(width: 52, alignment: .leading)
            Text(Format.celsius(current)).font(Typography.small).foregroundStyle(Palette.heat(current)).frame(width: 34, alignment: .trailing)
            Spacer(minLength: 4)
            Stepper(value: Binding(get: { threshold.start }, set: { threshold.start = min($0, threshold.full - 3) }), in: range, step: 1) {
                Text("on \(Int(threshold.start))°").font(Typography.small).foregroundStyle(Palette.secondary)
            }
            Stepper(value: Binding(get: { threshold.full }, set: { threshold.full = max($0, threshold.start + 3) }), in: range, step: 1) {
                Text("max \(Int(threshold.full))°").font(Typography.small).foregroundStyle(Palette.secondary)
            }
        }
        .controlSize(.small)
    }
}

// MARK: - Status

private struct HelperNotice: View {
    let state: ControlStatus.Helper
    static let installCommand = "cd ~/prog/swift/fan && make && sudo make install-helper"

    var body: some View {
        switch state {
        case .unused, .connected:
            EmptyView()
        case .notInstalled:
            VStack(alignment: .leading, spacing: 6) {
                Label("Fan control needs the helper, installed once with admin rights:", systemImage: "lock.shield")
                    .font(Typography.label).foregroundStyle(Palette.warn)
                HStack {
                    Text(Self.installCommand).font(Typography.code).textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.installCommand, forType: .string)
                    }
                    .controlSize(.small)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.track))
            }
        case .unavailable(let reason):
            Label("Helper unavailable: \(reason)", systemImage: "exclamationmark.triangle.fill")
                .font(Typography.label).foregroundStyle(Palette.warn)
        }
    }
}

private struct ControlStatusLine: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let c = monitor.control
        HStack(spacing: 6) {
            Image(systemName: c.targetRPM == nil ? "apple.logo" : "slider.horizontal.3")
            if let rpm = c.targetRPM {
                Text("Holding \(Format.rpm(rpm)) rpm")
            } else {
                Text(c.note ?? "macOS is in control")
            }
            if c.helper == .connected {
                Spacer()
                Label("Helper connected", systemImage: "checkmark.shield.fill").foregroundStyle(Palette.good)
            }
        }
        .font(Typography.small)
        .foregroundStyle(Palette.secondary)
    }
}
