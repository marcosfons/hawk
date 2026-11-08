//
//  AlertsPanel.swift
//  Hawk
//
//  The bell in the header: recent alerts, and what to be alerted about.
//

import HawkKit
import SwiftUI

struct AlertsButton: View {
    @Environment(Monitor.self) private var monitor
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
            monitor.alertsSeen()
        } label: {
            Image(systemName: monitor.unseenAlerts > 0 ? "bell.badge.fill" : "bell")
                .foregroundStyle(monitor.unseenAlerts > 0 ? Palette.warn : Palette.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(monitor.unseenAlerts > 0 ? "\(monitor.unseenAlerts) new alerts" : "Alerts")
        .popover(isPresented: $shown, arrowEdge: .bottom) { AlertsPanel().frame(width: 420).environment(monitor) }
    }
}

private struct AlertsPanel: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Alerts").font(.system(size: 14, weight: .semibold))
                Spacer()
                if !monitor.alerts.isEmpty { Button("Clear") { monitor.clearAlerts() }.controlSize(.small) }
            }
            if monitor.alerts.isEmpty {
                Text("Nothing so far.").font(Typography.label).foregroundStyle(Palette.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(monitor.alerts) { a in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(a.title).font(Typography.label)
                                    Spacer()
                                    Text(Format.ago(a.date)).font(Typography.caption).foregroundStyle(Palette.tertiary)
                                }
                                Text(a.body).font(Typography.small).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
            Divider()
            AlertSettingsForm()
        }
        .padding(16)
    }
}

private struct AlertSettingsForm: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        @Bindable var monitor = monitor
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            Rule(on: $monitor.alertSettings.lowDisk, label: "Free disk below") {
                Stepper("\(Int(monitor.alertSettings.lowDiskGB)) GB", value: $monitor.alertSettings.lowDiskGB, in: 5...100, step: 5)
            }
            Rule(on: $monitor.alertSettings.memoryPressure, label: "Memory pressure for 2 min") {
                Stepper(Format.percent(monitor.alertSettings.pressure), value: $monitor.alertSettings.pressure, in: 0.5...0.95, step: 0.05)
            }
            Rule(on: $monitor.alertSettings.swapGrowth, label: "Swap grows in 10 min by") {
                Stepper(String(format: "%.1f GB", monitor.alertSettings.swapGBPer10Min), value: $monitor.alertSettings.swapGBPer10Min, in: 0.5...10, step: 0.5)
            }
            Rule(on: $monitor.alertSettings.leaks, label: "A process grows per minute, 5 min") {
                Stepper("\(Int(monitor.alertSettings.leakMBPerMinute)) MB", value: $monitor.alertSettings.leakMBPerMinute, in: 20...1000, step: 20)
            }
            Rule(on: $monitor.alertSettings.hotChip, label: "Chip above, for 1 min") {
                Stepper("\(Int(monitor.alertSettings.chipCelsius)) °C", value: $monitor.alertSettings.chipCelsius, in: 70...105, step: 1)
            }
            Rule(on: $monitor.alertSettings.hotBattery, label: "Battery above, for 1 min") {
                Stepper("\(Int(monitor.alertSettings.batteryCelsius)) °C", value: $monitor.alertSettings.batteryCelsius, in: 32...50, step: 1)
            }
            Rule(on: $monitor.alertSettings.batteryDrain, label: "One app on battery, 5 min") {
                Stepper(String(format: "%.0f W", monitor.alertSettings.appWatts), value: $monitor.alertSettings.appWatts, in: 1...30, step: 1)
            }
        }
        .font(Typography.small)
        .controlSize(.small)
        Toggle("Also send macOS notifications", isOn: $monitor.alertSettings.notify).font(Typography.small)
    }
}

private struct Rule<Control: View>: View {
    @Binding var on: Bool
    let label: String
    @ViewBuilder var control: Control

    var body: some View {
        GridRow {
            Toggle(label, isOn: $on)
            control.disabled(!on).gridColumnAlignment(.trailing)
        }
    }
}
