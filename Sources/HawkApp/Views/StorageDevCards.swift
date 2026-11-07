//
//  StorageDevCards.swift
//  Hawk
//
//  iOS & Xcode (simulators, runtimes, DerivedData per project, the rest) and
//  Stremio (cache against its cap, and how it regrows), as compact columns.
//

import AppKit
import HawkKit
import SwiftUI

/// Column header for the small grids in these cards.
private struct Header: View {
    let titles: [String]

    var body: some View {
        GridRow {
            ForEach(titles.indices, id: \.self) { i in
                Text(titles[i]).font(Typography.caption).foregroundStyle(Palette.tertiary)
                    .gridColumnAlignment(i == 0 ? .leading : .trailing)
            }
        }
        Divider().gridCellUnsizedAxes(.horizontal).overlay(Palette.cardStroke)
    }
}

private struct Section: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(Typography.cardTitle).foregroundStyle(Palette.secondary)
            Spacer()
            if let detail { Text(detail).font(Typography.small).foregroundStyle(Palette.secondary) }
        }
        .padding(.top, 4)
    }
}

struct XcodeCard: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let ids = ["simulator-runtimes", "ios-simulators", "xcode-derived-data", "orphaned-simulator-assets",
                   "xcode-archives", "xcode-device-support", "cocoapods-cache"]
        let total = ids.compactMap { storage.entry($0)?.sizeBytes }.reduce(0, +)
        Card(title: "iOS & Xcode", symbol: "hammer.fill") {
            Text(Format.bytes(Double(total))).font(Typography.value)
        } content: {
            Simulators()
            Runtimes()
            DerivedData()
            Others()
        }
    }
}

private struct Simulators: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let devices = storage.simulators
        Section(title: "Simulators", detail: devices.isEmpty ? nil : Format.bytes(Double(devices.compactMap(\.bytes).reduce(0, +))))
        if devices.isEmpty {
            Text("None").font(Typography.small).foregroundStyle(Palette.tertiary)
        } else {
            Grid(horizontalSpacing: 12, verticalSpacing: 4) {
                Header(titles: ["Device", "Runtime", "State", "Size", "Last used", ""])
                ForEach(devices.prefix(8)) { d in
                    GridRow {
                        Text(d.name).lineLimit(1)
                        Text(d.runtime).foregroundStyle(Palette.secondary)
                        Text(d.booted ? "Running" : d.available ? "Off" : "Unavailable")
                            .foregroundStyle(d.booted ? Palette.good : d.available ? Palette.secondary : Palette.warn)
                        Text(d.bytes.map { Format.bytes(Double($0)) } ?? "-").monospacedDigit()
                        Text(Format.ago(d.lastUsed)).foregroundStyle(Palette.secondary)
                        if d.booted {
                            Image(systemName: "lock.fill").foregroundStyle(Palette.tertiary).help("Running: shut it down first")
                        } else {
                            Button { storage.requestSimulatorDelete(d) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                                .disabled(storage.working.contains("cmd:xcrun simctl delete \(d.udid)"))
                                .help("Delete this simulator…")
                        }
                    }
                    .font(Typography.small)
                }
            }
        }
    }
}

private struct Runtimes: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        if let entry = storage.entry("simulator-runtimes") {
            Section(title: "Simulator runtimes", detail: Format.bytes(Double(entry.sizeBytes ?? 0)))
            Grid(horizontalSpacing: 12, verticalSpacing: 4) {
                Header(titles: ["Runtime", "Size", "Last used", ""])
                ForEach(entry.children) { c in
                    GridRow {
                        Text(c.why?.components(separatedBy: " · ").first ?? Xcode.runtimeName(c.path)).lineLimit(1)
                        Text(Format.bytes(Double(c.bytes))).monospacedDigit()
                        Text(c.lastUsed ?? "never").foregroundStyle(c.lastUsed == nil ? Palette.warn : Palette.secondary)
                        if let id = c.identifier {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString("xcrun simctl runtime delete \(id)", forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                                .help("Copy the delete command (run it in Terminal)")
                        }
                    }
                    .font(Typography.small)
                }
            }
        }
    }
}

private struct DerivedData: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        if let entry = storage.entry("xcode-derived-data") {
            let items = entry.children.filter { storage.derived[$0.path]?.project != nil }.sorted { $0.bytes > $1.bytes }
            Section(title: "DerivedData by project", detail: Format.bytes(Double(entry.sizeBytes ?? 0)))
            Grid(horizontalSpacing: 12, verticalSpacing: 4) {
                Header(titles: ["Project", "Size", "Opened", ""])
                ForEach(items.prefix(8)) { c in
                    GridRow {
                        Text(storage.derived[c.path]?.project ?? "?").lineLimit(1).help(c.path)
                        Text(Format.bytes(Double(c.bytes))).monospacedDigit()
                        Text(Format.ago(storage.derived[c.path]?.lastOpened)).foregroundStyle(Palette.secondary)
                        DeleteOrLock(entry: entry, child: c)
                    }
                    .font(Typography.small)
                }
            }
        }
    }
}

private struct Others: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let rows = ["orphaned-simulator-assets", "xcode-device-support", "cocoapods-cache", "xcode-archives"].compactMap { storage.entry($0) }
        Section(title: "Also", detail: nil)
        Grid(horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows) { e in
                GridRow {
                    HStack(spacing: 6) {
                        Circle().fill(e.risk.color).frame(width: 7, height: 7)
                        Text(e.name).lineLimit(1)
                    }
                    .gridColumnAlignment(.leading)
                    Text(Format.bytes(Double(e.sizeBytes ?? 0))).monospacedDigit().gridColumnAlignment(.trailing)
                    Text(e.risk.label).foregroundStyle(e.risk.color)
                    Button("Details") { storage.selection = e.id }.buttonStyle(.link).font(Typography.caption)
                }
                .font(Typography.small)
            }
        }
    }
}

private struct DeleteOrLock: View {
    let entry: StorageEntry
    let child: StorageEntry.Child
    @Environment(StorageModel.self) private var storage

    var body: some View {
        if case .blocked(let why) = storage.verdict(entry, path: child.path) {
            Image(systemName: "lock.fill").foregroundStyle(Palette.tertiary).help(why)
        } else {
            Button { storage.requestDelete(entry, child: child) } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                .disabled(storage.working.contains("path:" + child.path))
                .help("Delete…")
        }
    }
}

struct StremioCard: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let entry = storage.entry("stremio-cache")
        let size = entry?.sizeBytes ?? 0
        let cap = storage.stremioCap
        let open = storage.running.bundleIDs.contains { $0.hasPrefix("com.stremio.") || $0.hasPrefix("com.westbridge.stremio") }
        Card(title: "Stremio", symbol: "play.rectangle.fill") {
            Text(Format.bytes(Double(size))).font(Typography.value)
        } content: {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    Text("Cache").font(Typography.caption).foregroundStyle(Palette.tertiary)
                    if let cap, cap > 0 {
                        HStack(spacing: 8) {
                            MeterBar(value: Double(size) / Double(cap), color: Palette.load(Double(size) / Double(cap)))
                            Text("\(Format.bytes(Double(size))) of \(Format.bytes(Double(cap))) cap").font(Typography.small).fixedSize()
                        }
                    } else {
                        Text("No cap set: Settings > Player > Cache size").font(Typography.small).foregroundStyle(Palette.warn)
                    }
                }
                GridRow {
                    Text("30 days").font(Typography.caption).foregroundStyle(Palette.tertiary)
                    let g = storage.growth["stremio-cache"] ?? 0
                    Text(abs(g) < 0.05 ? "no change" : String(format: "%+.1f GB", g)).font(Typography.small)
                        .foregroundStyle(g >= 0.05 ? Palette.warn : Palette.secondary)
                }
                GridRow {
                    Text("App").font(Typography.caption).foregroundStyle(Palette.tertiary)
                    Text(open ? "Open: the cache can only be cleared once it is closed" : "Closed")
                        .font(Typography.small).foregroundStyle(open ? Palette.warn : Palette.secondary)
                }
            }
            let history = storage.series["stremio-cache"] ?? []
            if history.count > 1 {
                Sparkline(values: history, color: Palette.upload, maximum: max(history.max() ?? 1, 0.1))
                    .frame(height: 36)
                    .help("Cache size over the recent scans")
            }
            if let entry {
                HStack {
                    Spacer()
                    Button("Clear cache…") { storage.requestReclaim(entry) }
                        .controlSize(.small)
                        .disabled(open || size == 0 || StorageRules.runnableReclaim(entry) == nil)
                }
            }
        }
    }
}
