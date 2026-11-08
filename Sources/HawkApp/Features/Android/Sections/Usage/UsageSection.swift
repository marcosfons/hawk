//
//  UsageSection.swift
//  Hawk
//
//  Usage per app (requirements 3.4): battery since the last charge, Wi-Fi and
//  mobile data for a period, background data, and memory now, one row per app
//  (apps sharing a UID together; removed apps and the hotspot as their own rows).
//

import HawkKit
import SwiftUI

struct UsageSection: View {
    let context: SectionContext
    @State private var model = UsageModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            UsageToolbar(model: model, live: context.isLive) { Task { await model.refresh(context) } }
            if let status = model.status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
            DataTable(columns: Self.columns, rows: model.rows, sortKey: "battery", menu: nil, onSelect: nil)
                .tableCard()
                .frame(minHeight: 260, maxHeight: .infinity)
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

    private static func bytes(_ v: Int64?) -> String { v.map { Format.bytes(Double($0)) } ?? "-" }

    static let columns: [Column<UsageRow>] = [
        Column(id: "app", title: "App", width: 240, flexible: true, numeric: false, text: \.title,
               tooltip: { $0.packages.isEmpty ? "UID \($0.id)" : $0.packages.joined(separator: ", ") },
               less: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }),
        Column(id: "battery", title: "Battery", width: 110,
               text: { r in r.mAh.map { String(format: "%.0f mAh - %@", $0, Format.percent(r.batteryShare ?? 0)) } ?? "-" },
               less: { ($0.mAh ?? 0) < ($1.mAh ?? 0) }),
        Column(id: "wifi", title: "Wi-Fi", width: 80, text: { bytes($0.wifi) }, less: { ($0.wifi ?? 0) < ($1.wifi ?? 0) }),
        Column(id: "mobile", title: "Mobile", width: 80, text: { bytes($0.mobile) }, less: { ($0.mobile ?? 0) < ($1.mobile ?? 0) }),
        Column(id: "background", title: "Background", width: 86, text: { bytes($0.background) },
               less: { ($0.background ?? 0) < ($1.background ?? 0) }),
        Column(id: "memory", title: "Memory now", width: 90, text: { $0.memoryKB.map { Format.bytes(Double($0) * 1024) } ?? "-" },
               less: { ($0.memoryKB ?? 0) < ($1.memoryKB ?? 0) }),
    ]
}

private struct UsageToolbar: View {
    @Bindable var model: UsageModel
    let live: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Period", selection: $model.period) {
                ForEach(UsagePeriod.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 360)
            .disabled(model.dataSinceCharge)
            Text(model.dataSinceCharge ? "Data and battery since the last charge" : "Battery since the last charge")
                .font(Typography.caption).foregroundStyle(Palette.secondary)
            Spacer()
            if model.refreshing { ProgressView().controlSize(.small) }
            Text(model.updated.map { "Read \(Format.ago($0))" } ?? "").font(Typography.caption).foregroundStyle(Palette.tertiary)
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!live || model.refreshing)
                .accessibilityLabel("Refresh usage")
        }
    }
}
