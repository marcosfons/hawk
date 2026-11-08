//
//  LogcatSection.swift
//  Hawk
//
//  The Logcat page (requirements 4): chips and a filter bar that are one filter,
//  the live list, and a detail pane. Logcat streams only while this page is shown
//  for a live device; leaving it stops the phone's logcat.
//

import AppKit
import HawkKit
import SwiftUI

struct LogcatSection: View {
    let context: SectionContext

    private var model: LogcatModel { LogcatRegistry.shared.model(for: context.device.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LogChips(model: model)
            LogFilterBar(model: model)
            LogTable(rows: model.rows, version: model.version, app: model.appName,
                     onSelect: { model.selected = $0 }, menu: menu)
                .frame(minHeight: 200, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.card))
            if let e = model.selected { LogDetail(entry: e, group: model.rows.filter { $0.group != nil && $0.group == e.group }) }
        }
        .task(id: Key(device: context.device.id, live: context.isLive, shown: context.shown, capacity: model.capacity)) {
            let model = model
            guard context.isLive, context.shown else {
                model.detach()
                return
            }
            model.attach(context)
            // Held until the page goes away (or the key changes), then let go.
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
            model.detach()
        }
    }

    private struct Key: Equatable { let device: DeviceID; let live: Bool; let shown: Bool; let capacity: Int }

    private func menu(_ e: LogEntry) -> [ContextAction?] {
        let model = model
        let app = model.appName(e).name
        let packages = e.uid.flatMap { uid in model.packages.first { $0.title == app }.map { [$0.name] } } ?? []
        var items: [ContextAction?] = []
        if let pkg = packages.first {
            items.append(ContextAction(title: "Only This App") { model.setFilter(LogFilter(parsing: "package:\(pkg)")) })
        }
        items.append(ContextAction(title: "Only This Tag") { model.setFilter(LogFilter(parsing: "tag=:\(e.tag)")) })
        items.append(ContextAction(title: "Hide This Tag") { model.setFilter(LogFilter(parsing: (model.filter.text + " -tag:\(e.tag)").trimmingCharacters(in: .whitespaces))) })
        items.append(ContextAction(title: "Only This PID") { model.setFilter(LogFilter(parsing: "pid:\(e.pid)")) })
        items.append(nil)
        items.append(ContextAction(title: "Copy") { copy("\(e.tag): \(e.message)") })
        items.append(ContextAction(title: "Copy as Filter") { copy("tag=:\(e.tag)") })
        return items
    }
}

private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// Level, quick filters and apps; each writes the same filter the bar shows.
private struct LogChips: View {
    let model: LogcatModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(LogLevel.allCases, id: \.self) { level in
                let on = model.filter.minimumLevel == level
                Button(level.letter) { model.setFilter(model.filter.setting(minimumLevel: on ? nil : level)) }
                    .buttonStyle(.bordered).tint(on ? Palette.accent : nil)
                    .accessibilityLabel("Minimum level \(level.letter)")
            }
            Divider().frame(height: 18)
            ForEach([("Crashes", "crash"), ("ANRs", "anr"), ("Flutter", "flutter"), ("Flutter errors", "flutter-error")], id: \.1) { title, kind in
                Button(title) { model.setFilter(model.filter.toggling(kind: kind)) }
                    .buttonStyle(.bordered).tint(model.filter.has(kind: kind) ? Palette.accent : nil)
            }
            Divider().frame(height: 18)
            Menu("Apps (\(model.filter.packages.count))") {
                ForEach(model.packages, id: \.name) { p in
                    Button((model.filter.packages.contains(p.name) ? "- " : "") + p.title) { model.setFilter(model.filter.toggling(package: p.name)) }
                }
            }
            .frame(maxWidth: 140)
            Spacer()
            Text(model.running ? "\(model.rows.count) shown of \(model.total)" : (model.ended ?? "Not running"))
                .font(Typography.caption).foregroundStyle(Palette.secondary)
        }
        .controlSize(.small)
    }
}

private struct LogFilterBar: View {
    @Bindable var model: LogcatModel

    var body: some View {
        HStack(spacing: 8) {
            TextField("Filter: package:com.example.app level:warn -tag:chatty | tag=:flutter", text: $model.filterText)
                .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
            if !model.invalid.isEmpty {
                Text("Ignored: " + model.invalid.joined(separator: " ")).font(Typography.caption).foregroundStyle(Palette.hot).lineLimit(1)
            }
            Picker("Keep", selection: $model.capacity) {
                // About 0.4 KB per line in memory.
                ForEach(LogcatModel.capacities, id: \.self) { n in
                    Text("\(n / 1000)k lines (~\(n * 4 / 10_000) MB)").tag(n)
                }
            }
            .fixedSize()
            .help("How many lines Hawk keeps in memory; changing it reads the log again")
            Toggle("Keep running", isOn: $model.keepRunning).toggleStyle(.button)
                .tint(model.keepRunning ? Palette.hot : nil)
                .help("Keep streaming when this page closes, until switched off or Hawk quits")
            Button(model.recordingTo == nil ? "Record..." : "Stop recording", systemImage: model.recordingTo == nil ? "record.circle" : "stop.circle") {
                if model.recordingTo != nil {
                    model.stopRecording()
                } else {
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "logcat-recording.txt"
                    if panel.runModal() == .OK, let url = panel.url { model.startRecording(to: url) }
                }
            }
            .tint(model.recordingTo == nil ? nil : Palette.hot)
            Toggle("Pause", isOn: $model.paused).toggleStyle(.button)
            Button("Export...", systemImage: "square.and.arrow.up") {
                let panel = NSSavePanel()
                panel.nameFieldStringValue = "logcat.txt"
                panel.allowedContentTypes = [.plainText]
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let model = model
                Task {
                    let text = await model.exportText()
                    do { try text.write(to: url, atomically: true, encoding: .utf8) } catch {
                        Log.app.error("Could not export logcat: \(error.localizedDescription)")
                    }
                }
            }
            .labelStyle(.iconOnly).accessibilityLabel("Export the visible lines")
            Button("Clear", systemImage: "trash") { model.clear() }.labelStyle(.iconOnly).accessibilityLabel("Clear the log")
        }
        .controlSize(.small)
    }
}

/// The selected line in full; for a crash, its whole group; JSON pretty-printed.
private struct LogDetail: View {
    let entry: LogEntry
    let group: [LogEntry]

    var body: some View {
        ScrollView {
            Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }
        .frame(height: 160)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius).fill(Palette.card))
    }

    private var text: String {
        if group.count > 1 { return group.map(\.message).joined(separator: "\n") }
        if entry.kind == .json, let data = entry.message.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) {
            return "\(entry.tag)\n" + String(decoding: pretty, as: UTF8.self)
        }
        return "\(entry.tag) (\(entry.kind.filterName))\n\(entry.message)"
    }
}
