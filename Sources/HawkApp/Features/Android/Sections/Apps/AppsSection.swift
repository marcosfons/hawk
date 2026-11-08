//
//  AppsSection.swift
//  Hawk
//
//  Every app on the device (requirements 3.1, 3.3): icon, label, package,
//  version, source, user or system, enabled, sizes, dates, target SDK; filters and
//  search; actions from the context menu, each through AndroidRules and logged.
//

import AppKit
import HawkKit
import SwiftUI

struct AppsSection: View {
    let context: SectionContext
    @State private var model = AppsModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            AppsToolbar(model: model, live: context.isLive) { Task { await model.refresh(context) } }
            if let status = model.status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
            table
        }
        .task(id: Key(device: context.device.id, live: context.isLive, shown: context.shown)) {
            await model.load(context)
            if context.isLive, context.shown { await model.refresh(context) }
        }
    }

    private var table: some View {
        let actions: (([AppEntry]) -> [ContextAction?])? = context.isLive ? { menu($0) } : nil
        let model = model, context = context
        return DataTable(columns: columns, rows: model.shown, sortKey: "label", menu: actions, onSelect: nil)
            .tableCard()
            .frame(minHeight: 260, maxHeight: .infinity)
            // Drop .apk files on the list to install them.
            .dropDestination(for: URL.self) { urls, _ in
                guard context.isLive, !urls.isEmpty else { return false }
                Task { await model.install(urls, context: context) }
                return true
            }
    }

    private struct Key: Equatable { let device: DeviceID; let live: Bool; let shown: Bool }

    private var columns: [Column<AppEntry>] {
        let icons = model.icons
        return [
            Column(id: "label", title: "App", width: 220, flexible: true, numeric: false, text: \.title,
                   icon: { icons[$0.name] }, tooltip: { $0.name }, less: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }),
            Column(id: "package", title: "Package", width: 220, numeric: false, text: \.name, color: { _ in .secondaryLabelColor },
                   less: { $0.name < $1.name }),
            Column(id: "version", title: "Version", width: 90, numeric: false, text: { $0.versionName ?? $0.versionCode.map(String.init) ?? "-" },
                   less: { ($0.versionCode ?? 0) < ($1.versionCode ?? 0) }),
            Column(id: "source", title: "From", width: 100, numeric: false, text: \.source, less: { $0.source < $1.source }),
            Column(id: "kind", title: "Kind", width: 64, numeric: false, text: { $0.isSystem ? "System" : "User" },
                   less: { !$0.isSystem && $1.isSystem }),
            Column(id: "enabled", title: "State", width: 70, numeric: false, text: { $0.enabled ? "Enabled" : "Disabled" },
                   color: { $0.enabled ? nil : NSColor(Palette.warn) }, less: { !$0.enabled && $1.enabled }),
            Column(id: "size", title: "Total", width: 76, text: { $0.totalSize.map { Format.bytes(Double($0)) } ?? "-" },
                   less: { ($0.totalSize ?? -1) < ($1.totalSize ?? -1) }),
            Column(id: "data", title: "Data", width: 76, text: { $0.dataSize.map { Format.bytes(Double($0)) } ?? "-" },
                   less: { ($0.dataSize ?? -1) < ($1.dataSize ?? -1) }),
            Column(id: "cache", title: "Cache", width: 70, text: { $0.cacheSize.map { Format.bytes(Double($0)) } ?? "-" },
                   less: { ($0.cacheSize ?? -1) < ($1.cacheSize ?? -1) }),
            Column(id: "updated", title: "Updated", width: 86, text: { $0.lastUpdate.map { Format.ago($0) } ?? "-" },
                   less: { ($0.lastUpdate ?? .distantPast) < ($1.lastUpdate ?? .distantPast) }),
            Column(id: "target", title: "Target SDK", width: 70, text: { $0.targetSdk.map(String.init) ?? "-" },
                   less: { ($0.targetSdk ?? 0) < ($1.targetSdk ?? 0) }),
        ]
    }

    private func menu(_ chosen: [AppEntry]) -> [ContextAction?] {
        guard let app = chosen.first else { return [] }
        let model = model, context = context
        func run(_ action: AndroidAction) { Task { await model.perform(action, app: app, context: context) } }
        var items: [ContextAction?] = []
        items.append(ContextAction(title: "Copy Package Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.name, forType: .string)
        })
        items.append(ContextAction(title: "Open on Device") { Task { await model.open(app, context: context) } })
        items.append(ContextAction(title: "Save APK...") {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = "Save Here"
            panel.message = "Choose a folder for \(app.title)'s APK files"
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            Task { await model.saveAPK(app, to: folder, context: context) }
        })
        items.append(nil)
        items.append(ContextAction(title: "Force Stop") { run(.forceStop(package: app.name)) })
        items.append(ContextAction(title: "Clear Cache") { run(.clearCache(package: app.name)) })
        let clearMessage = "Its accounts, settings, databases and files on the device are deleted. This cannot be undone."
        items.append(ContextAction(title: "Clear Data...", confirm: ("Clear all data of \(app.title)?", clearMessage, "Clear Data")) {
            run(.clearData(package: app.name))
        })
        items.append(nil)
        if app.enabled {
            let message = "It stops running and disappears until enabled again."
            items.append(ContextAction(title: "Disable...", confirm: ("Disable \(app.title)?", message, "Disable")) {
                run(.disable(package: app.name))
            })
        } else {
            items.append(ContextAction(title: "Enable") { run(.enable(package: app.name)) })
        }
        let uninstallMessage = app.isSystem
            ? "A system app is removed for user 0 only; cmd package install-existing brings it back."
            : "The app and its data are removed from the device."
        items.append(ContextAction(title: app.isSystem ? "Uninstall for This User..." : "Uninstall...",
                                   confirm: ("Uninstall \(app.title)?", uninstallMessage, "Uninstall")) {
            run(.uninstall(package: app.name))
        })
        return items
    }
}

private struct AppsToolbar: View {
    @Bindable var model: AppsModel
    let live: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $model.filter) {
                ForEach(AppFilter.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
            TextField("Search apps", text: $model.query).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            Text("\(model.shown.count) of \(model.apps.count)").font(Typography.caption).foregroundStyle(Palette.secondary)
            Spacer()
            if model.refreshing { ProgressView().controlSize(.small) }
            Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
                .disabled(!live || model.refreshing)
                .accessibilityLabel("Refresh apps")
        }
    }
}
