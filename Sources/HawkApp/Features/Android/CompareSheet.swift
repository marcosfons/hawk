//
//  CompareSheet.swift
//  Hawk
//
//  Two devices side by side (plan F5): system and app versions from what Hawk
//  keeps for each, settings read once from both when the page is opened. The
//  feature comes in as a parameter, never from the environment: a sheet has its
//  own hosting view, and an @Environment object read there can be missing.
//

import HawkKit
import SwiftUI

struct ComparePair: Identifiable {
    let a: Device
    let b: Device
    var id: String { a.id.rawValue + "|" + b.id.rawValue }
}

struct CompareSheet: View {
    let feature: AndroidFeature
    let pair: ComparePair
    @Environment(\.dismiss) private var dismiss

    private enum Page: String, CaseIterable, Identifiable {
        case system = "System", apps = "Apps", settings = "Settings"
        var id: Self { self }
    }

    @State private var page = Page.system
    @State private var loaded = false
    @State private var systemA: SystemInfo?
    @State private var systemB: SystemInfo?
    @State private var appsA: [AppEntry]?
    @State private var appsB: [AppEntry]?
    @State private var includeSystem = false
    @State private var showSame = false
    @State private var settings: [DeviceComparison.Row]?
    @State private var settingsError: String?
    @State private var readingSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Compare devices").font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("Page", selection: $page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            CompareRow(label: "", a: pair.a.name, b: pair.b.name, header: true)
            Divider()
            Group {
                switch page {
                case .system: systemPage
                case .apps: appsPage
                case .settings: settingsPage
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                Text("Values that differ are highlighted.").font(Typography.caption).foregroundStyle(Palette.tertiary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 780, height: 600)
        .task { await load() }
        .onChange(of: page) { if page == .settings { Task { await readSettings() } } }
    }

    // MARK: Pages

    @ViewBuilder private var systemPage: some View {
        if loaded, systemA == nil || systemB == nil {
            note("No system details kept for \(systemA == nil ? pair.a.name : pair.b.name) yet: open its Overview once while it is connected.")
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(DeviceComparison.system(systemA, systemB)) { r in
                    CompareRow(label: r.label, a: r.a, b: r.b, differs: r.differs)
                }
            }
        }
    }

    @ViewBuilder private var appsPage: some View {
        let rows = DeviceComparison.apps(appsA ?? [], appsB ?? [], includeSystem: includeSystem)
        let count = { (kind: DeviceComparison.AppRow.Kind) in rows.count(where: { $0.kind == kind }) }
        HStack(spacing: 14) {
            Text("\(count(.differs)) differ, \(count(.onlyA)) only on \(pair.a.name), \(count(.onlyB)) only on \(pair.b.name), \(count(.same)) the same")
                .font(Typography.small).foregroundStyle(Palette.secondary)
            Spacer()
            Toggle("System apps", isOn: $includeSystem)
            Toggle("Matching apps", isOn: $showSame)
        }
        .controlSize(.small)
        if loaded, appsA == nil || appsB == nil {
            note("No app list kept for \(appsA == nil ? pair.a.name : pair.b.name) yet: open its Apps section once while it is connected.")
        }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(rows.filter { showSame || $0.kind != .same }) { r in
                    CompareRow(label: r.label, a: r.a ?? "Not installed", b: r.b ?? "Not installed",
                               differs: r.kind != .same)
                }
            }
        }
    }

    @ViewBuilder private var settingsPage: some View {
        if !(pair.a.isConnected && pair.b.isConnected) {
            note("Settings are read from the devices themselves: connect both to compare them.")
        } else if let settingsError {
            note(settingsError)
        } else if let settings {
            Text(settings.isEmpty ? "The global and system settings are the same."
                                  : "\(settings.count) global and system settings differ (secure settings are not read: they hold identifiers).")
                .font(Typography.small).foregroundStyle(Palette.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(settings) { r in CompareRow(label: r.label, a: r.a, b: r.b, differs: true, code: true) }
                }
            }
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(Typography.small).foregroundStyle(Palette.secondary)
    }

    // MARK: Loading

    private func load() async {
        guard let store = feature.hub.store else { loaded = true; return }
        let a = pair.a.id, b = pair.b.id
        async let sa = store.load(OverviewSnapshot.self, OverviewModel.snapshotFile, for: a)
        async let sb = store.load(OverviewSnapshot.self, OverviewModel.snapshotFile, for: b)
        async let pa = store.load([AppEntry].self, AppsModel.file, for: a)
        async let pb = store.load([AppEntry].self, AppsModel.file, for: b)
        systemA = await sa?.system
        systemB = await sb?.system
        appsA = await pa
        appsB = await pb
        loaded = true
    }

    /// One shell call per device, once per sheet.
    private func readSettings() async {
        guard settings == nil, settingsError == nil, !readingSettings, pair.a.isConnected, pair.b.isConnected else { return }
        readingSettings = true
        defer { readingSettings = false }
        let hub = feature.hub
        func read(_ id: DeviceID) async throws -> [String: String] {
            let session = try await hub.session(for: id)
            let out = try await session.shell(DeviceComparison.settingsScript, timeout: .seconds(15))
            return DeviceComparison.parseSettings(out.stdout)
        }
        do {
            async let a = read(pair.a.id)
            async let b = read(pair.b.id)
            settings = try await DeviceComparison.settings(a, b)
        } catch {
            settingsError = "Could not read the settings: \((error as? AdbError)?.summary ?? error.localizedDescription)"
        }
    }
}

/// A label, then one value per device, the pair highlighted when they differ.
private struct CompareRow: View {
    let label: String
    let a: String
    let b: String
    var differs = false
    var header = false
    var code = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(code ? Typography.code : Typography.small).foregroundStyle(Palette.secondary)
                .lineLimit(1).truncationMode(.middle)
                .frame(width: 230, alignment: .leading)
            value(a)
            value(b)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(header ? Typography.cardTitle : code ? Typography.code : Typography.small)
            .textCase(header ? .uppercase : nil)
            .foregroundStyle(header ? Palette.secondary : differs ? Palette.warn : .white)
            .lineLimit(2).truncationMode(.middle)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
