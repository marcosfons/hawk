//
//  NetworkView.swift
//  Hawk
//
//  Network traffic per process (from nettop), refreshed every 2 s while open.
//

import AppKit
import HawkKit
import SwiftUI

nonisolated struct NetworkRow: Identifiable, Sendable {
    let id: Int32
    let name: String
    let path: String?
    let rx: Double
    let tx: Double
    let rxTotal: UInt64
    let txTotal: UInt64
}

struct NetworkView: View {
    @Environment(Monitor.self) private var monitor
    @State private var search = ""

    var body: some View {
        // nettop truncates names; the process list (sampled in the background) has full paths.
        let known = Dictionary(monitor.processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let q = search.trimmingCharacters(in: .whitespaces)
        let rows = monitor.network.compactMap { n -> NetworkRow? in
            let name = known[n.pid]?.name ?? n.name
            guard q.isEmpty || name.localizedCaseInsensitiveContains(q) || String(n.pid) == q else { return nil }
            return NetworkRow(id: n.pid, name: name, path: known[n.pid]?.path, rx: n.rxRate, tx: n.txRate, rxTotal: n.rxTotal, txTotal: n.txTotal)
        }
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                SearchField(text: $search, prompt: "Search name or PID", width: 220)
                Text("\(rows.count) processes - down \(Format.rate(rows.map(\.rx).reduce(0, +))) - up \(Format.rate(rows.map(\.tx).reduce(0, +)))")
                    .font(Typography.small).foregroundStyle(Palette.secondary)
                Spacer()
            }
            DataTable(columns: Self.columns, rows: rows, sortKey: "rx").tableCard()
            Text("Downloaded and uploaded count since each process started.")
                .font(Typography.caption).foregroundStyle(Palette.tertiary).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }
}

extension NetworkView {
    static let columns: [Column<NetworkRow>] = [
        Column(id: "name", title: "Process", width: 280, flexible: true, numeric: false, text: \.name,
               icon: { IconCache.shared.icon(forExecutable: $0.path) ?? IconCache.daemon },
               less: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }),
        Column(id: "rx", title: "Down", width: 84, text: { $0.rx > 0 ? Format.rate($0.rx) : "0" },
               color: { $0.rx > 0 ? NSColor(Palette.download) : .tertiaryLabelColor }, less: { $0.rx < $1.rx }),
        Column(id: "tx", title: "Up", width: 84, text: { $0.tx > 0 ? Format.rate($0.tx) : "0" },
               color: { $0.tx > 0 ? NSColor(Palette.upload) : .tertiaryLabelColor }, less: { $0.tx < $1.tx }),
        Column(id: "rxTotal", title: "Downloaded", width: 90, text: { Format.bytes(Double($0.rxTotal)) },
               color: { _ in .secondaryLabelColor }, less: { $0.rxTotal < $1.rxTotal }),
        Column(id: "txTotal", title: "Uploaded", width: 90, text: { Format.bytes(Double($0.txTotal)) },
               color: { _ in .secondaryLabelColor }, less: { $0.txTotal < $1.txTotal }),
        Column(id: "pid", title: "PID", width: 60, text: { "\($0.id)" }, color: { _ in .secondaryLabelColor }, less: { $0.id < $1.id }),
    ]
}
