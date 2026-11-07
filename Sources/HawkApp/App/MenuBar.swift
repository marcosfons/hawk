//
//  MenuBar.swift
//  Hawk
//
//  The menu bar item: a template hawk-eye icon (tinted by macOS for light and
//  dark menu bars), optionally the chip temperature next to it, and a compact
//  panel. The label reads only the Monitor's `headline`, which changes when a
//  shown figure changes, so it costs nothing between those changes.
//

import AppKit
import HawkKit
import SwiftUI

enum MenuBarIcon {
    /// 18 pt, drawn in code so it stays sharp at any scale: an eye under a swept brow,
    /// like the app icon, in one colour.
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let iris = NSBezierPath(ovalIn: NSRect(x: 4.4, y: 6.2, width: 9.8, height: 9.8))
            iris.lineWidth = 1.6
            iris.stroke()
            NSBezierPath(ovalIn: NSRect(x: 8.6, y: 9.2, width: 4.3, height: 4.3)).fill()
            // A wedge: thin at the back, sweeping forward to a point that dips over the eye.
            let brow = NSBezierPath()
            brow.move(to: NSPoint(x: 0.8, y: 6.6))
            brow.curve(to: NSPoint(x: 8.6, y: 3.0), controlPoint1: NSPoint(x: 3.2, y: 4.8), controlPoint2: NSPoint(x: 5.6, y: 3.2))
            brow.curve(to: NSPoint(x: 17.4, y: 8.4), controlPoint1: NSPoint(x: 12.6, y: 2.7), controlPoint2: NSPoint(x: 15.8, y: 4.8))
            brow.curve(to: NSPoint(x: 10.0, y: 6.4), controlPoint1: NSPoint(x: 14.8, y: 6.7), controlPoint2: NSPoint(x: 12.4, y: 6.2))
            brow.curve(to: NSPoint(x: 0.8, y: 6.6), controlPoint1: NSPoint(x: 6.4, y: 6.6), controlPoint2: NSPoint(x: 3.2, y: 7.0))
            brow.close()
            // A clear outline first, so the brow stands apart from the iris it overlaps.
            NSGraphicsContext.current?.compositingOperation = .clear
            brow.lineWidth = 2.2
            brow.stroke()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            brow.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Hawk"
        return image
    }()
}

struct MenuBarLabel: View {
    @Environment(AppModel.self) private var app
    @Environment(Monitor.self) private var monitor

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: MenuBarIcon.image)
            if app.menuShowsTemperature, let chip = monitor.headline.chip {
                Text("\(chip)°").monospacedDigit()
            }
        }
    }
}

/// The panel under the menu bar icon: the essentials, fan mode, recent alerts.
struct MenuPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        @Bindable var monitor = monitor
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22)
                Text("Hawk").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Open Hawk") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .controlSize(.small)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Stat(label: "CPU", value: Format.percent(s.cpuTotal), color: Palette.load(s.cpuTotal))
                    Stat(label: "Chip", value: Format.celsius(s.socMax), color: Palette.heat(s.socMax))
                    Stat(label: "GPU", value: Format.percent(s.gpu ?? 0), color: Palette.gpu)
                }
                GridRow {
                    Stat(label: "Power", value: Format.watts(s.systemPower), color: Palette.power)
                    Stat(label: "Battery", value: s.power.map { "\($0.percent)%" } ?? "-", color: Palette.battery)
                    Stat(label: "Pressure", value: s.memory.map { Format.percent($0.pressure) } ?? "-",
                         color: Palette.load(s.memory?.pressure ?? 0))
                }
                GridRow {
                    Stat(label: "Down", value: Format.rate(s.netRx), color: Palette.download)
                    Stat(label: "Up", value: Format.rate(s.netTx), color: Palette.upload)
                    Stat(label: "Disk free", value: s.volumes.first.map { Format.bytes(Double($0.available)) } ?? "-", color: .white)
                }
            }
            if let p = s.power { ChargeLabel(power: p, batteryTemp: s.batteryTemp) }
            Divider()
            HStack {
                let rpm = s.fans.map(\.actual).max() ?? 0
                Label(rpm < 1 ? "Fans off" : "Fans \(Format.rpm(rpm)) rpm", systemImage: "fanblades.fill").font(Typography.label)
                Spacer()
                Picker("Fan mode", selection: $monitor.settings.mode) {
                    Text("Auto").tag(FanMode.auto)
                    Text("Curve").tag(FanMode.curve)
                    Text("Fixed").tag(FanMode.fixed)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
            }
            if !monitor.alerts.isEmpty {
                Divider()
                ForEach(monitor.alerts.prefix(3)) { a in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "bell.fill").foregroundStyle(Palette.warn).font(.system(size: 10))
                        Text(a.title).font(Typography.small).lineLimit(1)
                        Spacer()
                        Text(Format.ago(a.date)).font(Typography.caption).foregroundStyle(Palette.tertiary)
                    }
                }
            }
            Divider()
            Toggle("Show chip temperature in the menu bar", isOn: $app.menuShowsTemperature)
            Toggle("Open at login", isOn: Binding(get: { app.opensAtLogin }, set: { app.opensAtLogin = $0 }))
            HStack {
                Text("Hawk \(String(format: "%.1f%%", monitor.selfCPU * 100)) - \(Format.bytes(Double(monitor.selfMemory)))")
                    .font(Typography.caption).foregroundStyle(Palette.tertiary)
                Spacer()
                Button("Quit Hawk") { NSApp.terminate(nil) }.controlSize(.small)
            }
        }
        .font(Typography.small)
        .toggleStyle(.checkbox)
        .padding(14)
        .frame(width: 340)
        .preferredColorScheme(.dark)
        .onAppear { app.menuPanel(open: true) }
        .onDisappear { app.menuPanel(open: false) }
    }
}

private struct Stat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(Typography.value).foregroundStyle(color)
            Text(label).font(Typography.caption).foregroundStyle(Palette.secondary)
        }
        .frame(minWidth: 90, alignment: .leading)
    }
}
