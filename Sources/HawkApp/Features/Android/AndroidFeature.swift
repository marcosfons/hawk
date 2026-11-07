//
//  AndroidFeature.swift
//  Hawk
//
//  The Android tab, a starting point for the adb toolkit: every connected device
//  (USB, Wi-Fi, emulators) and details for the selected one. It shows the
//  pattern a self-contained feature follows:
//
//  - state on the main actor in the feature (`@Observable`), read by its view;
//  - slow work (running adb) in an actor of its own, so the UI never waits;
//  - a Refresher for the schedule: every 2 s while the tab is visible, never in
//    the background (nothing here needs to run with the tab closed).
//

import HawkKit
import Observation
import SwiftUI

@Observable
final class AndroidFeature: Feature {
    let id = "android"
    let title = "Android"
    let symbol = "candybarphone"

    private(set) var devices: [AndroidDevice] = []
    private(set) var details: [String: AndroidDetails] = [:]
    private(set) var adbMissing = Adb.executable == nil
    var selectedSerial: String?

    @ObservationIgnored private let worker = AndroidWorker()
    @ObservationIgnored private lazy var refresher = Refresher("android", foreground: .seconds(2), background: nil) { [weak self] in
        await self?.refresh()
    }

    func makeView() -> AnyView { AnyView(AndroidView(feature: self)) }

    func setVisible(_ visible: Bool) { refresher.visible = visible }

    var selected: AndroidDevice? { devices.first { $0.serial == selectedSerial } ?? devices.first }

    private func refresh() async {
        guard let list = await worker.devices() else { adbMissing = Adb.executable == nil; devices = []; return }
        if list != devices { devices = list }
        // Details change slowly (battery aside): fetch for the selected device every 30 s.
        if let device = selected, device.isReady,
           Date().timeIntervalSince(details[device.serial]?.fetchedAt ?? .distantPast) > 30,
           let d = await worker.details(device.serial) {
            details[device.serial] = d
        }
    }
}

/// Runs adb off the main actor.
private actor AndroidWorker {
    func devices() -> [AndroidDevice]? { Log.app.timed("adb devices", warnAbove: 1500) { Adb.devices() } }
    func details(_ serial: String) -> AndroidDetails? { Log.app.timed("adb details", warnAbove: 3000) { Adb.details(serial) } }
}

private struct AndroidView: View {
    let feature: AndroidFeature

    var body: some View {
        VStack(spacing: Metrics.spacing) {
            if feature.adbMissing {
                ContentUnavailableView("adb not found", systemImage: "candybarphone",
                                       description: Text("Install Android platform-tools (Android Studio's SDK Manager, or brew install android-platform-tools)."))
            } else if feature.devices.isEmpty {
                ContentUnavailableView("No devices", systemImage: "cable.connector",
                                       description: Text("Connect a phone with USB debugging on, start an emulator, or pair one over Wi-Fi."))
            } else {
                HStack(alignment: .top, spacing: Metrics.spacing) {
                    DataTable(columns: Self.columns, rows: feature.devices, sortKey: "serial", menu: Self.menu,
                              onSelect: { feature.selectedSerial = $0?.serial })
                        .tableCard()
                        .frame(minWidth: 380)
                    if let device = feature.selected {
                        DeviceCard(device: device, details: feature.details[device.serial]).frame(width: 340)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    static let columns: [Column<AndroidDevice>] = [
        Column(id: "serial", title: "Device", width: 200, flexible: true, numeric: false, text: { $0.model ?? $0.serial },
               less: { ($0.model ?? $0.serial) < ($1.model ?? $1.serial) }),
        Column(id: "connection", title: "Connection", width: 90, numeric: false, text: \.connection, less: { $0.connection < $1.connection }),
        Column(id: "state", title: "State", width: 100, numeric: false, text: { $0.isReady ? "Ready" : $0.state.capitalized },
               color: { $0.isReady ? NSColor(Palette.good) : NSColor(Palette.warn) }, less: { $0.state < $1.state }),
        Column(id: "id", title: "Serial", width: 160, numeric: false, text: \.serial, color: { _ in .secondaryLabelColor },
               less: { $0.serial < $1.serial }),
    ]

    static func menu(_ chosen: [AndroidDevice]) -> [ContextAction?] {
        guard let device = chosen.first else { return [] }
        return [ContextAction(title: "Copy Serial") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(device.serial, forType: .string)
        }]
    }
}

private struct DeviceCard: View {
    let device: AndroidDevice
    let details: AndroidDetails?

    var body: some View {
        Card(title: device.model ?? device.serial, symbol: "candybarphone") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Maker", details?.manufacturer)
                row("Android", details.flatMap { d in d.android.map { "\($0) (API \(d.sdk ?? "?"))" } })
                row("Battery", details?.battery.map { "\($0)%" })
                row("Connection", device.connection)
                row("Serial", device.serial)
            }
            if !device.isReady {
                Text(device.state == "unauthorized" ? "Accept the debugging prompt on the device." : "The device is \(device.state).")
                    .font(Typography.small).foregroundStyle(Palette.warn)
            }
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).font(Typography.caption).foregroundStyle(Palette.tertiary).gridColumnAlignment(.trailing)
            Text(value ?? "-").font(Typography.small).textSelection(.enabled)
        }
    }
}
