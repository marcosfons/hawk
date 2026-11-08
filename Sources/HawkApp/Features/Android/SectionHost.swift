//
//  SectionHost.swift
//  Hawk
//
//  The sections of a device, in order, and the host that shows the selected one.
//  The list is Plan A's: later plans replace the contents of their own
//  `Sections/<Name>/<Name>Section.swift` and never edit this list.
//

import HawkKit
import SwiftUI

enum AndroidSection: String, CaseIterable, Identifiable {
    case overview, live, apps, usage, screen, logcat, crashes, performance, power, storage, network, security, tools, shell, doctor

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .live: "Live"
        case .apps: "Apps"
        case .usage: "Usage per app"
        case .screen: "Screen"
        case .logcat: "Logcat"
        case .crashes: "Crashes and ANRs"
        case .performance: "Performance"
        case .power: "Background and power"
        case .storage: "Storage"
        case .network: "Network"
        case .security: "Security"
        case .tools: "Tools"
        case .shell: "Shell"
        case .doctor: "Connection doctor"
        }
    }

    /// Pages built around one long table: they fill the height instead of scrolling.
    var fillsHeight: Bool { [.logcat, .crashes, .apps, .usage].contains(self) }

    var symbol: String {
        switch self {
        case .overview: "info.circle"
        case .live: "waveform.path.ecg"
        case .apps: "square.grid.2x2"
        case .usage: "chart.bar"
        case .screen: "rectangle.on.rectangle"
        case .logcat: "text.alignleft"
        case .crashes: "exclamationmark.triangle"
        case .performance: "speedometer"
        case .power: "battery.75percent"
        case .storage: "internaldrive"
        case .network: "network"
        case .security: "lock.shield"
        case .tools: "wrench.and.screwdriver"
        case .shell: "terminal"
        case .doctor: "stethoscope"
        }
    }
}

/// What every section gets: the device (possibly disconnected, then showing what was
/// kept) and the hub for sessions and storage.
struct SectionContext {
    let device: Device
    /// Its connection events, oldest first.
    let events: [DeviceEvent]
    let hub: AndroidHub
    /// The section is on screen: periodic reads run only while this is true.
    let shown: Bool
    var isLive: Bool { device.state == .device }
}

struct SectionHost: View {
    let feature: AndroidFeature

    var body: some View {
        if let device = feature.device {
            VStack(alignment: .leading, spacing: Metrics.spacing) {
                if !device.isConnected {
                    Banner(text: "Disconnected - last seen \(Format.ago(device.lastSeen)). Showing what Hawk kept; actions are off until it is back.")
                } else if let state = device.state, state != .device {
                    Banner(text: state == .unauthorized
                           ? "Unauthorized: accept the debugging prompt on the phone. If it never appears, revoke USB debugging authorizations in Developer options and plug in again."
                           : "The device is \(state.word); Hawk can talk to it once it is ready.")
                }
                let context = SectionContext(device: device, events: feature.snapshot.events[device.id] ?? [], hub: feature.hub, shown: feature.visible)
                if feature.section.fillsHeight {
                    section(context).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                } else {
                    ScrollView { section(context) }
                }
            }
        } else {
            ContentUnavailableView("No device", systemImage: "cable.connector",
                                   description: Text("Connect a phone with USB debugging on, start an emulator, or pair one over Wi-Fi."))
        }
    }

    @ViewBuilder
    private func section(_ context: SectionContext) -> some View {
        switch feature.section {
        case .overview: OverviewSection(context: context, model: feature.overview)
        case .live: LiveSection(context: context)
        case .apps: AppsSection(context: context)
        case .usage: UsageSection(context: context)
        case .screen: ScreenSection(context: context)
        case .logcat: LogcatSection(context: context)
        case .crashes: CrashesSection(context: context)
        case .performance: PerformanceSection(context: context)
        case .power: PowerSection(context: context)
        case .storage: StorageSection(context: context)
        case .network: NetworkSection(context: context)
        case .security: SecuritySection(context: context)
        case .tools: ToolsSection(context: context)
        case .shell: ShellSection(context: context)
        case .doctor: DoctorSection(context: context)
        }
    }
}

struct Banner: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(Typography.small).foregroundStyle(Palette.warn)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.warn.opacity(0.1)))
    }
}

/// What a section shows until its plan builds it.
struct NotBuiltYet: View {
    let section: AndroidSection
    let plan: String
    var body: some View {
        ContentUnavailableView(section.title, systemImage: section.symbol, description: Text("Not built yet (plan \(plan))."))
            .frame(maxWidth: .infinity, minHeight: 240)
    }
}
