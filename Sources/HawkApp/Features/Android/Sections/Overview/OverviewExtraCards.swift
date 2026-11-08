//
//  OverviewExtraCards.swift
//  Hawk
//
//  The Overview's additive card slot (plan E): management. Who owns the device
//  or its profiles, and its users and profiles (a work profile, Samsung's Secure
//  Folder). Read when the Overview opens for a live device; kept for when it is
//  away.
//

import HawkKit
import SwiftUI

struct OverviewExtraCards: View {
    let context: SectionContext
    @State private var management: Management?

    static let file = "management.json"

    var body: some View {
        Card(title: "Management", symbol: "building.2") {
            if let m = management {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                    row("Managed", m.isManaged ? "Yes" : "No")
                    row("Device owner", m.deviceOwner ?? "None")
                    ForEach(m.users, id: \.id) { u in
                        row("User \(u.id)", [u.name, u.managedProfile ? "profile" : nil, u.running ? "running" : "stopped",
                                             m.profileOwners[u.id].map { "owner \($0)" }].compactMap { $0 }.joined(separator: " - "))
                    }
                }
            } else {
                Text("-").font(Typography.small).foregroundStyle(Palette.secondary)
            }
        }
        .task(id: Key(device: context.device.id, live: context.isLive)) {
            management = await context.hub.store?.load(Management.self, Self.file, for: context.device.id)
            guard context.isLive, let session = try? await context.hub.session(for: context.device.id),
                  let parts = try? await session.shellBatch(Management.parts, timeout: .seconds(10)) else { return }
            let m = Management.parse(parts)
            management = m
            await context.hub.store?.save(m, as: Self.file, for: context.device.id)
        }
    }

    private struct Key: Equatable { let device: DeviceID; let live: Bool }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).font(Typography.caption).foregroundStyle(Palette.tertiary).gridColumnAlignment(.trailing)
            Text(value).font(Typography.small).textSelection(.enabled)
        }
    }
}
