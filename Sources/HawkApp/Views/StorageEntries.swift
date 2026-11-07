//
//  StorageEntries.swift
//  Hawk
//
//  Every registry entry as a sortable table, and the selected entry as a short
//  fact sheet plus a table of what is inside it, with per-item actions. Long
//  text (the description, care steps) is folded away until asked for. An item
//  can only be deleted when StorageRules allows it.
//

import AppKit
import HawkKit
import SwiftUI

nonisolated struct LocationRow: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let bytes: Int64
    let growth: Double
    let lastUsed: Date
    let risk: StorageEntry.Risk
    let riskOrder: Int
    let failed: Bool
}

struct EntriesCard: View {
    @Environment(StorageModel.self) private var storage
    @State private var order = [KeyPathComparator(\LocationRow.bytes, order: .reverse)]

    var body: some View {
        @Bindable var storage = storage
        let labels = storage.scan?.categories.mapValues(\.label) ?? [:]
        let rows = storage.filtered.map { e in
            LocationRow(id: e.id, name: e.name, category: labels[e.category] ?? e.category, bytes: e.sizeBytes ?? 0,
                        growth: storage.growth[e.id] ?? 0, lastUsed: storage.lastUsed(e) ?? .distantPast, risk: e.risk,
                        riskOrder: e.risk == .safe ? 0 : e.risk == .care ? 1 : 2, failed: e.error != nil)
        }
        Card(title: "Locations", symbol: "folder.fill") {
            HStack(spacing: 8) {
                SearchField(text: $storage.search, prompt: "Search", width: 150)
                Picker("Filter", selection: $storage.filter) {
                    ForEach(StorageModel.Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
            }
            .controlSize(.small)
        } content: {
            Table(rows.sorted(using: order), selection: $storage.selection, sortOrder: $order) {
                TableColumn("Location", value: \.name) { r in
                    HStack(spacing: 6) {
                        Circle().fill(r.risk.color).frame(width: 7, height: 7)
                        Text(r.name).lineLimit(1)
                        if r.failed { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warn).help("Could not be measured") }
                    }
                }
                .width(min: 150, ideal: 220)
                TableColumn("Category", value: \.category) { r in Text(r.category).foregroundStyle(Palette.secondary).lineLimit(1) }
                    .width(min: 70, ideal: 100)
                TableColumn("Size", value: \.bytes) { r in RightText(Format.bytes(Double(r.bytes))) }
                    .width(66)
                TableColumn("30 days", value: \.growth) { r in
                    RightText(abs(r.growth) < 0.05 ? "-" : String(format: "%+.1f GB", r.growth),
                              color: r.growth >= 0.05 ? Palette.warn : r.growth <= -0.05 ? Palette.good : Palette.tertiary)
                }
                .width(68)
                TableColumn("Last used", value: \.lastUsed) { r in
                    RightText(r.lastUsed == .distantPast ? "-" : Format.ago(r.lastUsed), color: Palette.secondary)
                }
                .width(74)
                TableColumn("Safety", value: \.riskOrder) { r in Text(r.risk.label).foregroundStyle(r.risk.color) }
                    .width(70)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .scrollContentBackground(.hidden)
            .font(Typography.small)
            .frame(height: 520)
        }
    }
}

struct RightText: View {
    let text: String
    var color: Color = .white

    init(_ text: String, color: Color = .white) { self.text = text; self.color = color }

    var body: some View {
        Text(text).foregroundStyle(color).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
    }
}

struct EntryDetailCard: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        if let entry = storage.entry(storage.selection) {
            Card(title: entry.name, symbol: "info.circle") {
                Text(entry.risk.label).font(Typography.caption).foregroundStyle(entry.risk.color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(entry.risk.color.opacity(0.15)))
            } content: {
                EntryFacts(entry: entry)
                if !entry.children.isEmpty { ChildrenTable(entry: entry) }
            }
        } else {
            Card(title: "Details", symbol: "info.circle") {
                Text("Pick a location.").font(Typography.label).foregroundStyle(Palette.secondary)
            }
        }
    }
}

/// Size and the three facts that matter, in a grid; everything wordy folds away.
private struct EntryFacts: View {
    let entry: StorageEntry
    @Environment(StorageModel.self) private var storage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(Format.bytes(Double(entry.sizeBytes ?? 0))).font(Typography.large)
                Text("measured \(Format.ago(entry.measuredAt))").font(Typography.caption).foregroundStyle(Palette.secondary)
                Spacer()
                Button("Re-measure") { storage.refresh(force: true, only: entry.id) }
                    .controlSize(.small).disabled(storage.scanning)
            }
            if let error = entry.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(Typography.small).foregroundStyle(Palette.warn).lineLimit(2)
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                FactRow(label: "If deleted", text: entry.onDelete)
                FactRow(label: "Comes back", text: entry.regeneratedBy)
                FactRow(label: "Cost", text: entry.rebuildCost)
            }
            HStack(spacing: 16) {
                if let d = entry.description, !d.isEmpty {
                    Folded(title: "About") { Text(d) }
                }
                if !entry.care.isEmpty {
                    Folded(title: "Care steps (\(entry.care.count))", tint: Palette.warn) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entry.care.indices, id: \.self) { i in Text("\(i + 1). \(entry.care[i])") }
                        }
                    }
                }
            }
            CleanupCommand(entry: entry)
        }
    }
}

private struct FactRow: View {
    let label: String
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            GridRow {
                Text(label).font(Typography.caption).foregroundStyle(Palette.tertiary).gridColumnAlignment(.trailing)
                Text(text).font(Typography.small).lineLimit(2).help(text)
            }
        }
    }
}

/// A title that reveals its text in a popover, so long prose never pushes the layout around.
private struct Folded<Content: View>: View {
    let title: String
    var tint: Color = Palette.accent
    @ViewBuilder var content: Content
    @State private var shown = false

    var body: some View {
        Button(title) { shown.toggle() }
            .buttonStyle(.link)
            .font(Typography.small)
            .tint(tint)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ScrollView {
                    content.font(Typography.label).fixedSize(horizontal: false, vertical: true).padding(14)
                }
                .frame(width: 380)
                .frame(maxHeight: 360)
            }
    }
}

private struct CleanupCommand: View {
    let entry: StorageEntry
    @Environment(StorageModel.self) private var storage

    var body: some View {
        if let command = entry.reclaim, !command.isEmpty, entry.risk != .never {
            let runnable = StorageRules.runnableReclaim(entry)
            HStack(spacing: 8) {
                Text(command).font(Typography.code).lineLimit(1).truncationMode(.middle).help(command)
                Spacer(minLength: 6)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                if let runnable {
                    Button("Run…") { storage.requestReclaim(entry) }
                        .disabled(storage.working.contains("cmd:" + runnable))
                } else {
                    Image(systemName: "terminal").foregroundStyle(Palette.tertiary)
                        .help("Needs filling in, admin rights or a manual step: run it in Terminal")
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Palette.track))
        }
    }
}

// MARK: - Children

nonisolated struct ChildRow: Identifiable, Sendable {
    let id: String
    let name: String
    let location: String
    let bytes: Int64
    let lastUsed: Date
    let child: StorageEntry.Child
}

private struct ChildrenTable: View {
    let entry: StorageEntry
    @Environment(StorageModel.self) private var storage
    @State private var order = [KeyPathComparator(\ChildRow.bytes, order: .reverse)]

    var body: some View {
        let rows = entry.children.map { c in
            let isPath = c.path.hasPrefix("/")
            let project = storage.derived[c.path]?.project
            return ChildRow(id: c.path,
                            name: project ?? (isPath ? (c.path as NSString).lastPathComponent : (c.why?.components(separatedBy: " · ").first ?? c.path)),
                            location: isPath ? Self.abbreviate((c.path as NSString).deletingLastPathComponent) : "",
                            bytes: c.bytes,
                            lastUsed: c.lastUsed.flatMap(StorageScan.parseDate) ?? storage.derived[c.path]?.lastOpened ?? storage.touched[c.path] ?? .distantPast,
                            child: c)
        }
        Table(rows.sorted(using: order), sortOrder: $order) {
            TableColumn("Item", value: \.name) { r in Text(r.name).lineLimit(1).truncationMode(.middle).help(r.id) }
                .width(min: 110, ideal: 170)
            TableColumn("In", value: \.location) { r in
                Text(r.location).foregroundStyle(Palette.tertiary).lineLimit(1).truncationMode(.head)
            }
            .width(min: 60, ideal: 120)
            TableColumn("Size", value: \.bytes) { r in RightText(Format.bytes(Double(r.bytes))) }
                .width(62)
            TableColumn("Last used", value: \.lastUsed) { r in
                RightText(r.lastUsed == .distantPast ? "-" : Format.ago(r.lastUsed), color: Palette.secondary)
            }
            .width(72)
            TableColumn("") { r in ChildAction(entry: entry, child: r.child) }
                .width(26)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .font(Typography.small)
        .frame(height: 300)
    }

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }
}

/// Delete, or a lock saying why not. Simulator runtimes live on system disk images and
/// go through simctl, so for them the button copies that command instead.
private struct ChildAction: View {
    let entry: StorageEntry
    let child: StorageEntry.Child
    @Environment(StorageModel.self) private var storage

    var body: some View {
        if !child.path.hasPrefix("/"), let identifier = child.identifier {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("xcrun simctl runtime delete \(identifier)", forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                .help("Copy: xcrun simctl runtime delete \(identifier)")
        } else {
            let verdict = storage.verdict(entry, path: child.path)
            switch verdict {
            case .blocked(let why):
                Image(systemName: "lock.fill").foregroundStyle(Palette.tertiary).help(why)
                    .accessibilityLabel("Cannot delete: \(why)")
            case .caution(let why):
                deleteButton(color: Palette.warn, help: "Delete… (\(why))")
            case .allowed:
                deleteButton(color: Palette.secondary, help: "Delete…")
            }
        }
    }

    private func deleteButton(color: Color, help: String) -> some View {
        Button { storage.requestDelete(entry, child: child) } label: { Image(systemName: "trash") }
            .buttonStyle(.plain).foregroundStyle(color)
            .disabled(storage.working.contains("path:" + child.path))
            .help(help)
            .accessibilityLabel("Delete \(child.path)")
    }
}
