//
//  SecurityFeature.swift
//  Hawk
//
//  The Security tab, a starting point for the light security scanner. It shows
//  the three kinds of work a feature can have:
//
//  - quick checks (startup items, where running programs live, who holds secret
//    files open) every 30 s while the tab is visible;
//  - a background watch, every 10 minutes with no window, that raises an alert
//    when a new startup item appears (the usual way malware stays on a Mac);
//  - a deep scan (every running program's code signature) that only runs when
//    asked, shows its progress, and says up front that it is heavier.
//

import AppKit
import HawkKit
import Observation
import SwiftUI

@Observable
final class SecurityFeature: Feature {
    let id = "security"
    let title = "Security"
    let symbol = "checkmark.shield"
    var needs: Set<Need> { [.processes] }

    private(set) var findings: [Finding] = []
    private(set) var items: [LaunchItem] = []
    private(set) var checkedAt: Date?
    private(set) var signatureFindings: [Finding] = []
    private(set) var signaturesCheckedAt: Date?
    /// 0...1 while the deep scan runs.
    private(set) var deepProgress: Double?
    var selected: Finding?

    @ObservationIgnored private let monitor: Monitor
    @ObservationIgnored private let worker = SecurityWorker()
    @ObservationIgnored private var visible = false
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private lazy var refresher = Refresher("security", foreground: .seconds(30), background: .seconds(600)) { [weak self] in
        await self?.check()
    }

    init(monitor: Monitor) {
        self.monitor = monitor
        _ = refresher      // starts the background watch
    }

    func makeView() -> AnyView { AnyView(SecurityView(feature: self)) }

    func setVisible(_ visible: Bool) {
        self.visible = visible
        refresher.visible = visible
    }

    func checkNow() { refresher.runNow() }

    var allFindings: [Finding] { (findings + signatureFindings).sorted { $0.severity > $1.severity } }

    private func check() async {
        // Process locations and secret files only while someone is looking; the startup
        // items watch runs either way.
        let result = await worker.quick(processes: visible ? monitor.processes : [], secrets: visible)
        items = result.items
        if visible { findings = result.findings } else { findings = findings.filter { $0.kind != "Startup item" } + result.findings.filter { $0.kind == "Startup item" } }
        checkedAt = Date()
        alertOnNewStartupItems(result.items)
    }

    private func alertOnNewStartupItems(_ items: [LaunchItem]) {
        let known = Set(defaults.stringArray(forKey: "knownStartupItems") ?? [])
        if !known.isEmpty {
            for item in items where !known.contains(item.plist) {
                Log.app.warning("New startup item: \(item.label) (\(item.plist))")
                monitor.post(FanAlert(key: "startup:\(item.plist)", title: "New startup item: \(item.label)",
                                      body: "Runs \(item.program ?? "an unknown program") (\(item.scope.lowercased())). Check it in the Security tab."))
            }
        }
        defaults.set(items.map(\.plist), forKey: "knownStartupItems")
    }

    func deepScan() {
        guard deepProgress == nil else { return }
        deepProgress = 0
        let paths = monitor.processes.compactMap(\.path) + items.compactMap(\.program).filter { $0.hasPrefix("/") }
        Log.app.info("Deep scan of \(Set(paths).count) programs started")
        Task {
            let found = await worker.signatures(paths) { [weak self] p in
                Task { @MainActor in if self?.deepProgress != nil { self?.deepProgress = p } }
            }
            signatureFindings = found
            signaturesCheckedAt = Date()
            deepProgress = nil
            Log.app.info("Deep scan finished: \(found.count) findings")
        }
    }
}

/// The checks, off the main actor.
private actor SecurityWorker {
    func quick(processes: [ProcessStat], secrets: Bool) -> (items: [LaunchItem], findings: [Finding]) {
        Log.app.timed("security quick checks", warnAbove: 1500) {
            let items = SecurityChecks.launchItems()
            return (items, SecurityChecks.quick(items: items, processes: processes) + (secrets ? SecurityChecks.secretFileAccess() : []))
        }
    }

    func signatures(_ paths: [String], progress: @Sendable (Double) -> Void) -> [Finding] {
        Log.app.timed("signature scan", warnAbove: 120_000) { SecurityChecks.signatures(paths, progress: progress) }
    }
}

private struct SecurityView: View {
    let feature: SecurityFeature

    var body: some View {
        let findings = feature.allFindings
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(findings.isEmpty ? "Nothing to look at" : "\(findings.count) thing\(findings.count == 1 ? "" : "s") to look at")
                        .font(Typography.large)
                    Text("Checked \(Format.ago(feature.checkedAt)) - startup items are also watched in the background")
                        .font(Typography.caption).foregroundStyle(Palette.secondary)
                }
                Spacer()
                Button("Check now") { feature.checkNow() }.controlSize(.small)
                if let progress = feature.deepProgress {
                    ProgressView(value: progress).frame(width: 120)
                    Text("Deep scan \(Format.percent(progress))").font(Typography.caption).foregroundStyle(Palette.secondary)
                } else {
                    Button("Deep scan…") { feature.deepScan() }
                        .controlSize(.small)
                        .help("Heavier: verifies the signature of every running program and startup item. Takes up to a minute and one core.")
                }
            }
            DataTable(columns: Self.findingColumns, rows: findings, sortKey: "severity", onSelect: { feature.selected = $0 })
                .tableCard()
                .frame(minHeight: 180)
            if let f = feature.selected {
                Text(f.detail).font(Typography.small).foregroundStyle(Palette.secondary).textSelection(.enabled)
            }
            Text("Startup items (\(feature.items.count))").font(Typography.cardTitle).foregroundStyle(Palette.secondary)
            DataTable(columns: Self.itemColumns, rows: feature.items, sortKey: "changed", menu: Self.itemMenu)
                .tableCard()
                .frame(minHeight: 160)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    static let findingColumns: [Column<Finding>] = [
        Column(id: "severity", title: "Level", width: 70, numeric: false,
               text: { $0.severity == .warning ? "Warning" : $0.severity == .notice ? "Notice" : "Info" },
               color: { $0.severity == .warning ? NSColor(Palette.hot) : $0.severity == .notice ? NSColor(Palette.warn) : .secondaryLabelColor },
               less: { $0.severity < $1.severity }),
        Column(id: "title", title: "What", width: 360, flexible: true, numeric: false, text: \.title, tooltip: { $0.detail },
               less: { $0.title < $1.title }),
        Column(id: "kind", title: "Kind", width: 100, numeric: false, text: \.kind, color: { _ in .secondaryLabelColor }, less: { $0.kind < $1.kind }),
        Column(id: "path", title: "Where", width: 260, numeric: false, text: { $0.path ?? "" }, color: { _ in .tertiaryLabelColor },
               less: { ($0.path ?? "") < ($1.path ?? "") }),
    ]

    static let itemColumns: [Column<LaunchItem>] = [
        Column(id: "label", title: "Label", width: 260, flexible: true, numeric: false, text: \.label, less: { $0.label < $1.label }),
        Column(id: "program", title: "Program", width: 300, numeric: false, text: { $0.program ?? "-" }, color: { _ in .secondaryLabelColor },
               less: { ($0.program ?? "") < ($1.program ?? "") }),
        Column(id: "scope", title: "For", width: 100, numeric: false, text: \.scope, less: { $0.scope < $1.scope }),
        Column(id: "changed", title: "Changed", width: 90, text: { Format.ago($0.modified) },
               less: { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }),
    ]

    static func itemMenu(_ chosen: [LaunchItem]) -> [ContextAction?] {
        guard let item = chosen.first else { return [] }
        var actions: [ContextAction?] = [ContextAction(title: "Show plist in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: item.plist)])
        }]
        if let program = item.program, program.hasPrefix("/") {
            actions.append(ContextAction(title: "Show program in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: program)])
            })
        }
        return actions
    }
}
