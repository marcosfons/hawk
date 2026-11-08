//
//  StorageSection.swift
//  Hawk
//
//  A device's storage (requirements 6): total and free, by class, volumes, the
//  storage type, and the apps using the most. One shell batch when the section
//  opens and every 5 minutes while it is shown (storage changes slowly); the last
//  reading is kept for when the device is away.
//

import HawkKit
import SwiftUI

struct StorageSection: View {
    let context: SectionContext
    @State private var model = DeviceStorageModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let error = model.error, context.isLive { Banner(text: "Could not read storage: \(error)") }
            if let s = model.storage {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.minCardWidth), spacing: Metrics.spacing, alignment: .top)],
                          alignment: .leading, spacing: Metrics.spacing) {
                    SummaryCard(storage: s, updated: model.updated, refreshing: model.refreshing,
                                refresh: context.isLive ? { Task { await model.refresh(context) } } : nil)
                    ClassesCard(storage: s)
                    VolumesCard(storage: s)
                    BiggestCard(apps: s.biggest(15), labels: model.labels)
                }
                SaverView(context: context)
            } else if model.refreshing {
                ProgressView("Reading storage").frame(maxWidth: .infinity, minHeight: 200)
            } else {
                ContentUnavailableView("No storage reading yet", systemImage: "internaldrive",
                                       description: Text("Hawk reads it when the device is connected."))
            }
        }
        .task(id: Key(device: context.device.id, live: context.isLive, shown: context.shown)) {
            await model.load(context)
            guard context.isLive, context.shown else { return }
            while !Task.isCancelled {
                await model.refresh(context)
                try? await Task.sleep(for: .seconds(300), tolerance: .seconds(30))
            }
        }
    }

    private struct Key: Equatable { let device: DeviceID; let live: Bool; let shown: Bool }
}

@Observable
final class DeviceStorageModel {
    private(set) var storage: DeviceStorage?
    private(set) var labels: [String: String] = [:]
    private(set) var updated: Date?
    private(set) var error: String?
    private(set) var refreshing = false
    @ObservationIgnored private var loadedFor: DeviceID?

    static let file = "storage.json"

    nonisolated struct Kept: Codable, Sendable {
        let storage: DeviceStorage
        let date: Date
    }

    /// The kept reading, once per device, so a disconnected device still shows it.
    func load(_ context: SectionContext) async {
        guard loadedFor != context.device.id else { return }
        loadedFor = context.device.id
        storage = nil
        updated = nil
        error = nil
        if let kept = await context.hub.store?.load(Kept.self, Self.file, for: context.device.id) {
            storage = kept.storage
            updated = kept.date
        }
        await loadLabels(context)
    }

    func refresh(_ context: SectionContext) async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let session = try await context.hub.session(for: context.device.id)
            let parts = try await session.shellBatch(DeviceStorage.parts, timeout: .seconds(15))
            let parsed = await Task.detached(priority: .utility) { DeviceStorage.parse(parts) }.value
            if parsed != storage { storage = parsed }
            updated = Date()
            error = nil
            await context.hub.store?.save(Kept(storage: parsed, date: updated ?? Date()), as: Self.file, for: context.device.id)
            await loadLabels(context)
        } catch {
            self.error = (error as? AdbError)?.summary ?? error.localizedDescription
        }
    }

    private func loadLabels(_ context: SectionContext) async {
        let index = await context.hub.packages(for: context.device.id)
        let found = index?.packages.compactMapValues(\.label) ?? [:]
        if found != labels { labels = found }
    }
}

private struct SummaryCard: View {
    let storage: DeviceStorage
    let updated: Date?
    let refreshing: Bool
    let refresh: (() -> Void)?

    var body: some View {
        Card(title: "Storage", symbol: "internaldrive") {
            HStack(spacing: 8) {
                Text(refreshing ? "Reading" : "Read \(Format.ago(updated))").font(Typography.caption).foregroundStyle(Palette.tertiary)
                if let refresh {
                    Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                        .labelStyle(.iconOnly).buttonStyle(.borderless).disabled(refreshing)
                        .accessibilityLabel("Refresh storage")
                }
            }
        } content: {
            if let total = storage.dataTotal, let free = storage.dataFree, total > 0 {
                Text("\(Format.bytes(Double(free))) free of \(Format.bytes(Double(total)))").font(Typography.value)
                StackedBar(segments: segments(total: total))
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Type", storage.storageType.map { storage.hasCardSlotInUse ? "\($0), plus a memory card" : $0 })
                row("Encryption", storage.fileBasedEncryption.map { $0 ? "File-based" : "Not file-based" })
            }
        }
    }

    private func segments(total: Int64) -> [StackedBar.Segment] {
        let colors: [DeviceStorage.Class: Color] = [.apps: Palette.accent, .appData: Palette.gpu, .appCache: Palette.memCached,
                                                    .photos: Palette.ssd, .videos: Palette.soc, .audio: Palette.battery,
                                                    .system: Palette.memWired, .other: Palette.tertiary]
        return DeviceStorage.Class.allCases.compactMap { c in
            guard let size = storage.classes[c], size > 0, let color = colors[c] else { return nil }
            return .init(id: c.rawValue, fraction: Double(size) / Double(total), color: color)
        }
    }
}

private struct ClassesCard: View {
    let storage: DeviceStorage

    var body: some View {
        Card(title: "By kind", symbol: "square.stack.3d.up") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(DeviceStorage.Class.allCases, id: \.self) { c in
                    row(c.title, storage.classes[c].map { Format.bytes(Double($0)) })
                }
            }
        }
    }
}

private struct VolumesCard: View {
    let storage: DeviceStorage

    var body: some View {
        Card(title: "Volumes", symbol: "externaldrive") {
            if storage.volumes.isEmpty {
                Text("No volumes listed.").font(Typography.small).foregroundStyle(Palette.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                    ForEach(storage.volumes, id: \.mount) { v in
                        row(v.kind, "\(Format.bytes(Double(v.free))) free of \(Format.bytes(Double(v.total)))")
                    }
                }
            }
        }
    }
}

private struct BiggestCard: View {
    let apps: [DeviceStorage.AppSize]
    let labels: [String: String]

    var body: some View {
        Card(title: "Biggest apps", symbol: "chart.bar.xaxis") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    Text("App").gridColumnAlignment(.leading)
                    Text("Total").gridColumnAlignment(.trailing)
                    Text("Data").gridColumnAlignment(.trailing)
                    Text("Cache").gridColumnAlignment(.trailing)
                }
                .font(Typography.caption).foregroundStyle(Palette.tertiary)
                ForEach(apps, id: \.package) { a in
                    GridRow {
                        Text(labels[a.package] ?? a.package).lineLimit(1).help(a.package)
                        Text(Format.bytes(Double(a.total))).monospacedDigit()
                        Text(Format.bytes(Double(a.data))).monospacedDigit().foregroundStyle(Palette.secondary)
                        Text(Format.bytes(Double(a.cache))).monospacedDigit().foregroundStyle(Palette.secondary)
                    }
                    .font(Typography.small)
                }
            }
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
