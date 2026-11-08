//
//  AndroidView.swift
//  Hawk
//
//  The Android tab's layout: the adb strip on top, devices and sections on the
//  left, the selected section on the right.
//

import HawkKit
import SwiftUI

struct AndroidView: View {
    let feature: AndroidFeature

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            AdbStrip(status: feature.snapshot.server, start: feature.startAdb, stop: feature.stopAdb, restart: feature.restartAdb)
            HStack(alignment: .top, spacing: Metrics.spacing) {
                Sidebar(feature: feature).frame(width: 240)
                SectionHost(feature: feature)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

/// Devices (live, then disconnected with when they were last seen), then sections.
private struct Sidebar: View {
    @Bindable var feature: AndroidFeature
    @State private var renaming: Device?
    @State private var newName = ""
    @State private var forgetting: Device?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                heading("Devices")
                if feature.snapshot.devices.isEmpty {
                    Text("No devices yet. Connect a phone with USB debugging on, or start an emulator.")
                        .font(Typography.small).foregroundStyle(Palette.secondary).padding(.horizontal, 8).padding(.bottom, 8)
                }
                ForEach(feature.snapshot.devices) { device in
                    DeviceRow(device: device, selected: device.id == feature.selectedDevice)
                        .contentShape(Rectangle())
                        .onTapGesture { feature.selectedDevice = device.id }
                        .contextMenu {
                            Button("Rename...") { newName = device.nickname ?? ""; renaming = device }
                            Button("Forget...") { forgetting = device }.disabled(device.isConnected)
                        }
                        .accessibilityAddTraits(.isButton)
                }
                Divider().padding(.vertical, 8)
                heading("Sections")
                ForEach(AndroidSection.allCases) { section in
                    SectionRow(section: section, selected: section == feature.section)
                        .contentShape(Rectangle())
                        .onTapGesture { feature.section = section }
                        .accessibilityAddTraits(.isButton)
                }
            }
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
        .alert("Rename device", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }), presenting: renaming) { device in
            TextField("Name", text: $newName)
            Button("Rename") { feature.rename(device.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Forget this device?", isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
                            presenting: forgetting) { device in
            Button("Forget \(device.name)", role: .destructive) { feature.forget(device.id) }
        } message: { _ in
            Text("Hawk deletes everything it kept about it: snapshot, history, events and its folder.")
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(Typography.cardTitle).textCase(.uppercase).tracking(0.6).foregroundStyle(Palette.secondary)
            .padding(.horizontal, 8).padding(.bottom, 4)
    }
}

private struct DeviceRow: View {
    let device: Device
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(device.name).font(Typography.label).lineLimit(1)
            }
            HStack(spacing: 4) {
                ForEach(device.transports.map(\.kind).sorted(), id: \.self) { kind in Chip(text: kind.label) }
                Text(status).font(Typography.caption).foregroundStyle(Palette.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.accent.opacity(0.22) : .clear))
        .accessibilityElement(children: .combine)
    }

    private var status: String {
        guard let state = device.state else { return "Disconnected - last seen \(Format.ago(device.lastSeen))" }
        return state == .device ? "live" : state.word
    }

    private var dot: Color {
        switch device.state {
        case .device: Palette.good
        case nil: Palette.tertiary
        default: Palette.warn
        }
    }
}

private struct SectionRow: View {
    let section: AndroidSection
    let selected: Bool

    var body: some View {
        Label(section.title, systemImage: section.symbol)
            .font(Typography.label)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Palette.accent.opacity(0.22) : .clear))
    }
}

struct Chip: View {
    let text: String
    var body: some View {
        Text(text).font(Typography.caption)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().strokeBorder(Palette.cardStroke).background(Capsule().fill(Palette.track)))
    }
}
