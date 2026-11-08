//
//  SecuritySection.swift
//  Hawk
//
//  Security and bloat (requirements 8): a local scan of user apps for access worth
//  a look, device-wide findings, preinstalled apps commonly removed with how safe
//  that is, and a way back for everything Hawk removed. On demand: the scan reads
//  several system dumps. Removing goes through AndroidRules and the action log.
//

import AppKit
import HawkKit
import SwiftUI

struct SecuritySection: View {
    let context: SectionContext
    @State private var result: AndroidSecurityScan.Result?
    @State private var labels: [String: String] = [:]
    @State private var bloat: [BloatEntry] = []
    @State private var scanning = false
    @State private var status: String?
    @State private var confirming: (BloatEntry, AndroidAction)?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Button(result == nil ? "Scan" : "Scan again", systemImage: "magnifyingglass") { Task { await scan() } }
                    .disabled(!context.isLive || scanning)
                if scanning { ProgressView().controlSize(.small) }
                Text("Looks at what user apps can access. Nothing leaves this Mac.").font(Typography.caption).foregroundStyle(Palette.secondary)
                Spacer()
            }
            .controlSize(.small)
            if let status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
            if let result {
                ForEach(result.device, id: \.self) { Banner(text: $0) }
                Card(title: "Apps worth a look (\(result.apps.count))", symbol: "exclamationmark.shield") {
                    ForEach(result.apps) { app in
                        HStack(alignment: .firstTextBaseline) {
                            Text(labels[app.package] ?? app.package).font(Typography.label).frame(width: 220, alignment: .leading).lineLimit(1)
                                .help(app.package)
                            Text(app.flags.map(\.title).joined(separator: ", ")).font(Typography.small)
                                .foregroundStyle(app.score >= 5 ? Palette.hot : app.score >= 3 ? Palette.warn : Palette.secondary)
                            Spacer()
                        }
                    }
                    if result.apps.isEmpty { Text("No user app holds powerful access.").font(Typography.small).foregroundStyle(Palette.secondary) }
                }
            }
            Card(title: "Preinstalled apps", symbol: "trash.slash") {
                Button("Restore everything Hawk removed") { Task { await restoreAll() } }
                    .buttonStyle(.borderless).font(Typography.caption).disabled(!context.isLive)
            } content: {
                if bloat.isEmpty {
                    Text(result == nil ? "Scan to list them." : "None of the known ones are installed.").font(Typography.small).foregroundStyle(Palette.secondary)
                }
                ForEach(bloat) { b in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.what).font(Typography.small)
                            Text("\(b.vendor) - \(b.package)").font(Typography.caption).foregroundStyle(Palette.tertiary)
                        }
                        Spacer()
                        Text(b.safety.rawValue).font(Typography.caption)
                            .foregroundStyle(b.safety == .safe ? Palette.good : b.safety == .probably ? Palette.warn : Palette.hot)
                        Button("Disable") { confirming = (b, .disable(package: b.package)) }
                        Button("Uninstall") { confirming = (b, .uninstall(package: b.package)) }
                    }
                    .controlSize(.small)
                    .disabled(!context.isLive)
                }
            }
        }
        .confirmationDialog(confirming.map { "\($0.1.name) \($0.0.what)?" } ?? "",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } })) {
            if let (entry, action) = confirming {
                Button(action.name, role: .destructive) { Task { await perform(action, entry.package) } }
            }
        } message: {
            Text("For user 0 only, and reversible: Restore everything Hawk removed brings it back.")
        }
    }

    private func scan() async {
        guard let session = try? await context.hub.session(for: context.device.id) else { return }
        scanning = true
        defer { scanning = false }
        if await context.hub.packages(for: context.device.id) == nil { await context.hub.refreshPackages(context.device.id) }
        let index = await context.hub.packages(for: context.device.id)
        labels = index?.packages.compactMapValues(\.label) ?? [:]
        let userApps = Set(index?.packages.values.filter { !$0.isSystem }.map(\.name) ?? [])
        guard let parts = try? await session.shellBatch(AndroidSecurityScan.parts, timeout: .seconds(60)) else {
            status = "The scan could not read the device"
            return
        }
        result = AndroidSecurityScan.parse(parts, userApps: userApps)
        bloat = BloatEntry.present(Set(index?.packages.keys.map { $0 } ?? []))
        status = nil
    }

    private func perform(_ action: AndroidAction, _ package: String) async {
        guard let session = try? await context.hub.session(for: context.device.id) else { return }
        let r = await AppActions.perform(action, isSystem: true, on: session, deviceName: context.device.name, store: context.hub.store)
        status = r == .done ? "\(action.name): \(package) - done" : "\(action.name) not done: \(r)"
        await context.hub.refreshPackages(context.device.id)
        if result != nil { await scan() }
    }

    private func restoreAll() async {
        guard let session = try? await context.hub.session(for: context.device.id),
              let folder = try? await context.hub.store?.folder(context.device.id),
              let log = try? String(contentsOf: folder.appending(path: ActionLog.fileName), encoding: .utf8) else {
            status = "Nothing to restore"
            return
        }
        let pending = RemovalRestore.pending(fromActionLog: log)
        guard !pending.isEmpty else { status = "Nothing to restore"; return }
        var done = 0
        for action in pending {
            if await AppActions.perform(action, isSystem: true, on: session, deviceName: context.device.name, store: context.hub.store) == .done { done += 1 }
        }
        status = "Restored \(done) of \(pending.count)"
        await context.hub.refreshPackages(context.device.id)
    }
}
