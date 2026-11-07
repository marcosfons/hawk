//
//  StorageView.swift
//  Hawk
//
//  The Storage tab: the disk headline, where space goes by category, what is
//  growing, every registry entry with its details and per-item actions, and
//  WhatsApp and Docker breakdowns. Data changes only when a scan lands, so
//  this tab costs nothing between scans.
//

import HawkKit
import SwiftUI

extension StorageEntry.Risk {
    var color: Color {
        switch self {
        case .safe: Palette.good
        case .care: Palette.warn
        case .never: Palette.accent.opacity(0.75)
        }
    }

    var label: String {
        switch self {
        case .safe: "Safe"
        case .care: "Care"
        case .never: "Protected"
        }
    }
}

struct StorageView: View {
    let wide: Bool
    @Environment(StorageModel.self) private var storage

    var body: some View {
        @Bindable var storage = storage
        ScrollView {
            VStack(spacing: Metrics.spacing) {
                StorageHeadline()
                if !storage.fullDiskAccess { AccessBanner() }
                if let error = storage.loadError {
                    ContentUnavailableView("No storage scan", systemImage: "internaldrive", description: Text(error))
                        .frame(height: 220)
                }
                if storage.scan != nil {
                    pair { CategoryCard() } second: { GrowthCard() }
                    pair { EntriesCard() } second: { EntryDetailCard() }
                    pair { XcodeCard() } second: { StremioCard() }
                }
                pair { WhatsAppCard() } second: { DockerCard() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
        .onAppear { storage.activate() }
        .onDisappear { storage.deactivate() }
        .sheet(item: $storage.pending) { DeletionSheet(request: $0) }
        .overlay(alignment: .bottom) { MessageToast() }
    }

    @ViewBuilder
    private func pair<A: View, B: View>(@ViewBuilder _ first: () -> A, @ViewBuilder second: () -> B) -> some View {
        if wide {
            HStack(alignment: .top, spacing: Metrics.spacing) { first(); second() }
        } else {
            first()
            second()
        }
    }
}

// MARK: - Headline

private struct StorageHeadline: View {
    @Environment(StorageModel.self) private var storage
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let scan = storage.scan
        let live = monitor.snapshot.volumes.first { $0.name == "Macintosh HD" }
        let total = live.map { Double($0.total) / 1e9 } ?? scan?.disk.totalGB ?? 0
        let free = live.map { Double($0.available) / 1e9 } ?? scan?.disk.freeGB ?? 0
        let safe = scan?.totals.safeGB ?? 0, care = scan?.totals.careGB ?? 0
        Card(title: "Disk", symbol: "internaldrive.fill") {
            HStack(spacing: 8) {
                if storage.scanning { ProgressView().controlSize(.small) }
                Text(storage.scanning ? "Scanning…" : "Scanned \(Format.ago(scan?.scannedAt))")
                    .font(Typography.caption).foregroundStyle(Palette.secondary)
                Button("Refresh") { storage.refresh() }
                    .disabled(storage.scanning)
                    .help("Re-measures only what is older than its TTL; cheap")
                Menu {
                    Button("Re-measure everything (~3 min)") { storage.refresh(force: true) }
                    Button("Open storage folder") { NSWorkspace.shared.open(storage.folder) }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            .controlSize(.small)
        } content: {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                BigStat(value: String(format: "%.1f GB", free), caption: "free of \(String(format: "%.0f", total)) GB",
                        color: free < 20 ? Palette.hot : free < 50 ? Palette.warn : Palette.good, font: Typography.hero)
                BigStat(value: String(format: "%.1f GB", safe), caption: "safe to clear", color: Palette.good)
                BigStat(value: String(format: "%.1f GB", care), caption: "clearable with care", color: Palette.warn)
            }
            let t = max(total, 1)
            StackedBar(segments: [
                .init(id: "safe", fraction: safe / t, color: Palette.good),
                .init(id: "care", fraction: care / t, color: Palette.warn),
                .init(id: "used", fraction: max(total - free - safe - care, 0) / t, color: Palette.memCached),
            ], height: 14)
            HStack(spacing: 14) {
                LegendDot(color: Palette.good, label: "safe to clear")
                LegendDot(color: Palette.warn, label: "with care")
                LegendDot(color: Palette.memCached, label: "everything else")
                LegendDot(color: Palette.track, label: "free")
            }
        }
    }
}

private struct LegendDot: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(Typography.caption).foregroundStyle(Palette.secondary)
        }
    }
}

// MARK: - Categories and growth

private struct CategoryCard: View {
    @Environment(StorageModel.self) private var storage

    struct Row: Identifiable {
        let id: String
        let label: String
        var safe = 0.0, care = 0.0, never = 0.0
        var total: Double { safe + care + never }
    }

    var body: some View {
        let rows = Self.rows(storage.scan)
        let top = rows.first?.total ?? 1
        Card(title: "Where it goes", symbol: "chart.bar.fill") {
            VStack(spacing: 6) {
                ForEach(rows.prefix(10)) { row in
                    HStack(spacing: 8) {
                        Text(row.label).font(Typography.small).lineLimit(1).frame(width: 130, alignment: .leading)
                        GeometryReader { geo in
                            HStack(spacing: 1) {
                                Rectangle().fill(Palette.good).frame(width: geo.size.width * row.safe / top)
                                Rectangle().fill(Palette.warn).frame(width: geo.size.width * row.care / top)
                                Rectangle().fill(Palette.accent.opacity(0.75)).frame(width: geo.size.width * row.never / top)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .frame(height: 10)
                        Text(String(format: "%.1f GB", row.total)).font(Typography.small).frame(width: 64, alignment: .trailing)
                    }
                }
            }
            HStack(spacing: 14) {
                LegendDot(color: Palette.good, label: "safe")
                LegendDot(color: Palette.warn, label: "care")
                LegendDot(color: Palette.accent.opacity(0.75), label: "protected")
            }
        }
    }

    static func rows(_ scan: StorageScan?) -> [Row] {
        guard let scan else { return [] }
        var by: [String: Row] = [:]
        for e in scan.entries where e.countInTotals && e.error == nil {
            let label = scan.categories[e.category]?.label ?? e.category
            var r = by[e.category] ?? Row(id: e.category, label: label)
            switch e.risk {
            case .safe: r.safe += e.gigabytes
            case .care: r.care += e.gigabytes
            case .never: r.never += e.gigabytes
            }
            by[e.category] = r
        }
        return by.values.sorted { $0.total > $1.total }
    }
}

private struct GrowthCard: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let growing = (storage.scan?.entries ?? [])
            .compactMap { e in storage.growth[e.id].flatMap { $0 > 0.1 ? (e, $0) : nil } }
            .sorted { $0.1 > $1.1 }
        Card(title: "Growing fastest, last 30 days", symbol: "chart.line.uptrend.xyaxis") {
            if growing.isEmpty {
                Text("Nothing grew more than 0.1 GB.").font(Typography.label).foregroundStyle(Palette.secondary)
            }
            VStack(spacing: 8) {
                ForEach(growing.prefix(8), id: \.0.id) { entry, gb in
                    HStack(spacing: 8) {
                        Circle().fill(entry.risk.color).frame(width: 7, height: 7)
                        Text(entry.name).font(Typography.small).lineLimit(1)
                        Spacer(minLength: 4)
                        let values = storage.series[entry.id] ?? []
                        Sparkline(values: values, color: entry.risk.color, maximum: values.max() ?? 1)
                            .frame(width: 90, height: 18)
                        Text(String(format: "+%.1f GB", gb)).font(Typography.small).foregroundStyle(Palette.warn)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { storage.selection = entry.id }
                }
            }
        }
    }
}

private struct AccessBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(Palette.warn)
            VStack(alignment: .leading, spacing: 2) {
                Text("Hawk needs Full Disk Access").font(Typography.label)
                Text("Without it macOS hides WhatsApp and the Trash from Hawk and from the scans it starts, so Hawk does not start scans on its own. Add Hawk in Privacy & Security > Full Disk Access, then reopen it.")
                    .font(Typography.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.warn.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).strokeBorder(Palette.warn.opacity(0.3)))
    }
}

// MARK: - Toast and sheet

private struct MessageToast: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        if let message = storage.message {
            HStack(spacing: 10) {
                Text(message).font(Typography.label)
                Button { storage.dismissMessage() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                    .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(Color(white: 0.16)))
            .overlay(Capsule().strokeBorder(Palette.cardStroke))
            .padding(.bottom, 14)
        }
    }
}

struct DeletionSheet: View {
    let request: DeletionRequest
    @Environment(StorageModel.self) private var storage
    @Environment(\.dismiss) private var dismiss
    @State private var acknowledged = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.system(size: 15, weight: .semibold))
            if let bytes = request.bytes {
                Text("\(Format.bytes(Double(bytes))) - \(request.entryName)").font(Typography.label).foregroundStyle(Palette.secondary)
            }
            Text(target).font(Typography.code).textSelection(.enabled)
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Palette.track))
            ForEach(request.details, id: \.self) { line in
                Text(line).font(Typography.label).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if request.needsAcknowledgement {
                Toggle("I have read this and want to go ahead", isOn: $acknowledged).font(Typography.label)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isCommand ? "Run" : "Delete", role: .destructive) { storage.perform(request) }
                    .disabled(request.needsAcknowledgement && !acknowledged)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var isCommand: Bool { if case .command = request.action { return true } else { return false } }

    private var target: String {
        switch request.action {
        case .path(let p): p
        case .command(let c): c
        case .dockerVolume(let v): "docker volume rm \(v)"
        }
    }
}
