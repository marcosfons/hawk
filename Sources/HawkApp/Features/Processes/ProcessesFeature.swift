//
//  ProcessesFeature.swift
//  Hawk
//
//  The CPU and Memory tabs: every process in a sortable table, with search.
//  They need the Monitor's process sample while visible.
//  Columns have fixed widths and CPU is smoothed in the sampler, so rows move
//  only when the ordering really changes. The table itself is AppKit
//  (DataTable.swift): SwiftUI's Table rebuilt every row view each second.
//

import HawkKit
import Observation
import SwiftUI

@Observable
final class ProcessesFeature: Feature {
    enum Kind { case cpu, memory }
    let kind: Kind
    var search = ""

    init(kind: Kind) { self.kind = kind }

    var id: String { kind == .cpu ? "cpu" : "memory" }
    var title: String { kind == .cpu ? "CPU" : "Memory" }
    var symbol: String { kind == .cpu ? "cpu" : "memorychip" }
    var needs: Set<Need> { [.processes] }

    func makeView() -> AnyView { AnyView(ProcessesView(feature: self)) }
}

private struct ProcessesView: View {
    @Bindable var feature: ProcessesFeature
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let kind = feature.kind
        let rows = filtered(monitor.processes, search: feature.search)
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                SearchField(text: $feature.search)
                ProcessSummary(kind: kind, shown: rows, total: monitor.processes.count)
                Spacer(minLength: 0)
                if let note = monitor.processNote {
                    Label(note, systemImage: "lock.shield")
                        .font(Typography.caption).foregroundStyle(Palette.secondary)
                        .lineLimit(1).truncationMode(.tail)
                        .help(note)
                }
            }
            switch kind {
            case .cpu: DataTable(columns: ProcessColumns.cpu, rows: rows, sortKey: "cpu", menu: ProcessColumns.menu).tableCard()
            case .memory: DataTable(columns: ProcessColumns.memory, rows: rows, sortKey: "memory", menu: ProcessColumns.menu).tableCard()
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func filtered(_ all: [ProcessStat], search: String) -> [ProcessStat] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.user.localizedCaseInsensitiveContains(q) || String($0.pid) == q }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search name, user or PID"
    var width: CGFloat = 280

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Palette.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Palette.tertiary)
                    .accessibilityLabel("Clear search")
            }
        }
        .font(Typography.label)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.card))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Palette.cardStroke))
    }
}

private struct ProcessSummary: View {
    let kind: ProcessesFeature.Kind
    let shown: [ProcessStat]
    let total: Int

    var body: some View {
        let count = shown.count == total ? "\(total) processes" : "\(shown.count) of \(total) processes"
        let detail = switch kind {
        case .cpu: "CPU \(Format.percent(shown.map(\.cpu).reduce(0, +))) - \(Format.processWatts(shown.map(\.power).reduce(0, +))) W"
        case .memory: "Memory \(Format.bytes(Double(shown.map(\.memory).reduce(0, +))))"
        }
        Text("\(count) - \(detail)")
            .font(Typography.small).foregroundStyle(Palette.secondary)
            .lineLimit(1)
    }
}

