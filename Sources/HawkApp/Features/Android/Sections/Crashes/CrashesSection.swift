//
//  CrashesSection.swift
//  Hawk
//
//  Crashes and ANRs of a device (requirements 5), newest first, from what the
//  CrashWatcher imported from the DropBox (it runs whether this page is open or
//  not). Selecting one shows its trace and, for an ANR, the logcat lines before it.
//

import AppKit
import HawkKit
import SwiftUI

struct CrashesSection: View {
    let context: SectionContext
    @State private var log = CrashLog()
    @State private var selected: CrashRecord?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if log.records.isEmpty {
                ContentUnavailableView("No crashes or ANRs", systemImage: "checkmark.seal",
                                       description: Text("Hawk checks the device's crash records on connection and every minute while it is connected."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                CountsCard(log: log)
                DataTable(columns: Self.columns, rows: log.records, sortKey: "date", menu: nil, onSelect: { selected = $0 })
                    .tableCard()
                    .frame(minHeight: 200, maxHeight: .infinity)
                if let r = selected { CrashDetail(record: r) }
            }
        }
        .task(id: Key(device: context.device.id, shown: context.shown)) {
            guard context.shown else { return }
            // The watcher writes the device's crash log; read it again while shown.
            while !Task.isCancelled {
                if let kept = await context.hub.store?.load(CrashLog.self, "crashes.json", for: context.device.id), kept != log { log = kept }
                try? await Task.sleep(for: .seconds(30), tolerance: .seconds(5))
            }
        }
    }

    private struct Key: Equatable { let device: DeviceID; let shown: Bool }

    static let columns: [Column<CrashRecord>] = [
        Column(id: "date", title: "When", width: 130, text: { $0.date.formatted(date: .abbreviated, time: .standard) },
               less: { $0.date < $1.date }),
        Column(id: "kind", title: "Kind", width: 100, numeric: false, text: \.kind.title,
               color: { $0.kind == .anr ? NSColor(Palette.warn) : NSColor(Palette.hot) }, less: { $0.kind.rawValue < $1.kind.rawValue }),
        Column(id: "app", title: "App", width: 220, numeric: false, text: { $0.package ?? $0.process ?? "-" },
               less: { ($0.package ?? "") < ($1.package ?? "") }),
        Column(id: "reason", title: "Reason", width: 400, flexible: true, numeric: false, text: \.reason, tooltip: { $0.reason },
               less: { $0.reason < $1.reason }),
    ]
}

private struct CountsCard: View {
    let log: CrashLog

    var body: some View {
        Card(title: "Per app", symbol: "chart.bar") {
            let top = log.counts().sorted { ($0.value.crashes + $0.value.anrs) > ($1.value.crashes + $1.value.anrs) }.prefix(6)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(top), id: \.key) { app, c in
                    GridRow {
                        Text(app).font(Typography.small).lineLimit(1)
                        Text("\(c.crashes) crashes").font(Typography.caption).foregroundStyle(Palette.secondary)
                        Text("\(c.anrs) ANRs").font(Typography.caption).foregroundStyle(Palette.secondary)
                    }
                }
            }
        }
    }
}

private struct CrashDetail: View {
    let record: CrashRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(record.kind.title): \(record.package ?? record.process ?? "-")").font(Typography.label)
                if let pid = record.pid { Text("PID \(pid)").font(Typography.caption).foregroundStyle(Palette.secondary) }
                if record.foreground == true { Text("in the foreground").font(Typography.caption).foregroundStyle(Palette.secondary) }
                Spacer()
                Button("Copy", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.body + (record.logcat.isEmpty ? "" : "\n\n" + record.logcat.joined(separator: "\n")), forType: .string)
                }
                .labelStyle(.iconOnly).buttonStyle(.borderless).accessibilityLabel("Copy the trace")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(record.body).textSelection(.enabled)
                    if !record.logcat.isEmpty {
                        Text("Logcat before it").font(Typography.caption).foregroundStyle(Palette.tertiary)
                        Text(record.logcat.joined(separator: "\n")).foregroundStyle(Palette.secondary).textSelection(.enabled)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 240)
        }
        .padding(Metrics.cardPadding)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.card))
    }
}
