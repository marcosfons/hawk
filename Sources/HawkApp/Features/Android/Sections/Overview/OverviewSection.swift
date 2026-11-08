//
//  OverviewSection.swift
//  Hawk
//
//  The first page of a device: right now (2.1), identity, the system in full
//  (2.3), recent connection events, and every property behind a disclosure.
//

import HawkKit
import SwiftUI

struct OverviewSection: View {
    let context: SectionContext
    let model: OverviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let error = model.error, context.isLive {
                Banner(text: "Could not read the device: \(error)")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.minCardWidth), spacing: Metrics.spacing, alignment: .top)],
                      alignment: .leading, spacing: Metrics.spacing) {
                RightNowCard(now: model.now, updated: model.updated, live: context.isLive)
                IdentityCard(device: context.device, system: model.system)
                SystemCard(system: model.system)
                EventsCard(events: context.events)
                OverviewExtraCards(context: context)
            }
            if let props = model.system?.props, !props.isEmpty {
                PropertiesList(props: props)
            }
        }
    }
}

private struct InfoRows: View {
    let rows: [(String, String?)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).font(Typography.caption).foregroundStyle(Palette.tertiary).gridColumnAlignment(.trailing)
                    Text(row.1 ?? "-").font(Typography.small).textSelection(.enabled).lineLimit(2)
                }
            }
        }
    }
}

private struct RightNowCard: View {
    let now: RightNow
    let updated: Date?
    let live: Bool

    var body: some View {
        Card(title: "Right now", symbol: "clock") {
            Text(live ? "" : "as of \(Format.ago(updated))").font(Typography.caption).foregroundStyle(Palette.tertiary)
        } content: {
            InfoRows(rows: [
                ("Foreground", now.foreground),
                ("Battery", battery),
                ("Temperature", now.battery?.temperature.map { String(format: "%.1f °C", $0) }),
                ("Health", now.battery?.health),
                ("Current", now.battery?.current.map { "\($0)" }),
                ("Screen", now.screenOn.map { $0 ? "On" : "Off" }),
                ("Locked", now.locked.map { $0 ? "Yes" : "No" }),
                ("Do Not Disturb", now.doNotDisturb),
            ])
        }
    }

    private var battery: String? {
        guard let b = now.battery else { return nil }
        let parts = [b.level.map { "\($0)%" }, b.status, b.source.map { "on \($0)" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " - ")
    }
}

private struct IdentityCard: View {
    let device: Device
    let system: SystemInfo?

    var body: some View {
        Card(title: "Identity", symbol: "candybarphone") {
            InfoRows(rows: [
                ("Name", device.name),
                ("Model", system?.model ?? device.model),
                ("Maker", system?.manufacturer),
                ("Android", system?.android.map { a in "\(a) (API \(system?.sdk ?? "?"))" }),
                ("Build", system?.build),
                ("Security patch", system?.securityPatch),
                ("Serial", device.id.rawValue),
                ("Connection", device.transports.isEmpty ? "Disconnected" : device.transports.map(\.kind.label).sorted().joined(separator: ", ")),
            ])
        }
    }
}

private struct SystemCard: View {
    let system: SystemInfo?

    var body: some View {
        Card(title: "System", symbol: "cpu") {
            InfoRows(rows: [
                ("SoC", system?.soc),
                ("Kernel", system?.kernel),
                ("Bootloader", system?.bootloaderLocked.map { $0 ? "Locked" : "Unlocked" }),
                ("Verified boot", system?.verifiedBoot),
                ("SELinux", system?.selinux),
                ("Encryption", system?.encryption),
                ("RAM", system?.ramKB.map { Format.bytes(Double($0) * 1024) }),
                ("Swap and zram", system?.swapKB.map { Format.bytes(Double($0) * 1024) }),
                ("Display", [system?.displaySize, system?.density.map { "\($0) dpi" }].compactMap { $0 }.joined(separator: " - ").nilIfEmpty),
                ("ABIs", system?.abis),
                ("Root", system.map { $0.rootIndicators.isEmpty ? "No signs" : $0.rootIndicators.joined(separator: ", ") }),
            ])
        }
    }
}

private struct EventsCard: View {
    let events: [DeviceEvent]

    var body: some View {
        Card(title: "Connection", symbol: "cable.connector") {
            if events.isEmpty {
                Text("No events yet.").font(Typography.small).foregroundStyle(Palette.secondary)
            } else {
                InfoRows(rows: events.suffix(8).reversed().map { ($0.date.formatted(date: .abbreviated, time: .shortened), $0.summary) })
            }
        }
    }
}

/// Every property, searchable; filtering waits for typing to pause and runs off the
/// main actor.
private struct PropertiesList: View {
    let props: [String: String]
    @State private var query = ""
    @State private var shown: [(key: String, value: String)] = []
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Filter properties", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.key) { p in
                        Text("\(p.key) = \(p.value)").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).lineLimit(1)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("All properties (\(props.count))").font(Typography.label)
        }
        .task(id: TaskKey(query: query, count: props.count, expanded: expanded)) {
            guard expanded else { return }
            if !query.isEmpty { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled else { return }
            let q = query.lowercased(), all = props
            let result = await Task.detached(priority: .userInitiated) {
                all.filter { q.isEmpty || $0.key.lowercased().contains(q) || $0.value.lowercased().contains(q) }
                    .sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value) }
            }.value
            if !Task.isCancelled { shown = result }
        }
    }

    private struct TaskKey: Equatable { let query: String; let count: Int; let expanded: Bool }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
