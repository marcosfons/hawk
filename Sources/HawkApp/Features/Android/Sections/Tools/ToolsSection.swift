//
//  ToolsSection.swift
//  Hawk
//
//  Developer tools (requirements 14.2): toggles in one panel (each change logged,
//  the original value kept so Reset all restores it), deep links and intents,
//  typing or pasting the Mac's clipboard into the focused field, and Flutter
//  DevTools from the Dart VM service in the phone's log buffer.
//

import AppKit
import HawkKit
import SwiftUI

struct ToolsSection: View {
    let context: SectionContext
    @State private var values: [String: String] = [:]
    @State private var originals: [String: String] = [:]
    @State private var link = ""
    @State private var text = ""
    @State private var status: String?
    @State private var busy = false

    private static let originalsFile = "toggles.json"

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
            Card(title: "Developer toggles", symbol: "switch.2") {
                ForEach(DevToggle.all) { t in
                    Toggle(t.title, isOn: Binding(get: { values[t.id].map(t.isOn) ?? false }, set: { on in Task { await set(t, on) } }))
                        .disabled(!context.isLive || busy || values[t.id] == nil)
                }
                if !originals.isEmpty {
                    Button("Reset all to how they were") { Task { await resetAll() } }.controlSize(.small).disabled(!context.isLive)
                }
            }
            Card(title: "Open a link or deep link", symbol: "link") {
                HStack {
                    TextField("https://example.com or myapp://screen", text: $link).textFieldStyle(.roundedBorder)
                    Button("Open") { Task { await run(DevCommands.open(link), "Opened \(link)") } }.disabled(!context.isLive || link.isEmpty)
                }
                .controlSize(.small)
            }
            Card(title: "Type on the device", symbol: "keyboard") {
                HStack {
                    TextField("Text for the focused field", text: $text).textFieldStyle(.roundedBorder)
                    Button("Type") { Task { await run(DevCommands.type(text), "Typed") } }.disabled(!context.isLive || text.isEmpty)
                    Button("Paste Mac clipboard") {
                        let clip = NSPasteboard.general.string(forType: .string) ?? ""
                        Task { await run(DevCommands.type(clip), "Pasted the clipboard") }
                    }
                    .disabled(!context.isLive)
                }
                .controlSize(.small)
            }
            Card(title: "Flutter", symbol: "hammer") {
                HStack {
                    Button("Open DevTools") { Task { await openDevTools() } }.disabled(!context.isLive || busy)
                    Text("Finds the running Flutter app's Dart VM service in the log buffer, forwards it and opens it.")
                        .font(Typography.caption).foregroundStyle(Palette.secondary)
                }
                .controlSize(.small)
            }
        }
        .task(id: Key(device: context.device.id, live: context.isLive)) { await load() }
    }

    private struct Key: Equatable { let device: DeviceID; let live: Bool }

    private func session() async -> (any DeviceSession)? { try? await context.hub.session(for: context.device.id) }

    private func load() async {
        originals = await context.hub.store?.load([String: String].self, Self.originalsFile, for: context.device.id) ?? [:]
        guard context.isLive, let session = await session() else { return }
        let parts = Dictionary(uniqueKeysWithValues: DevToggle.all.map { ($0.id, $0.read) })
        guard let out = try? await session.shellBatch(parts, timeout: .seconds(15)) else { return }
        values = Dictionary(uniqueKeysWithValues: DevToggle.all.compactMap { t in out[t.id].map { (t.id, t.value(from: $0)) } })
    }

    private func set(_ t: DevToggle, _ on: Bool) async {
        guard let session = await session(), let command = t.write(on ? t.on : t.off), let current = values[t.id] else { return }
        busy = true
        defer { busy = false }
        if originals[t.id] == nil {
            originals[t.id] = current
            await context.hub.store?.save(originals, as: Self.originalsFile, for: context.device.id)
        }
        let ok = (try? await session.shell(command, timeout: .seconds(10)))?.status == 0
        await log("\(t.title) \(on ? "on" : "off")", ok)
        await load()
    }

    private func resetAll() async {
        guard let session = await session() else { return }
        for t in DevToggle.all {
            guard let original = originals[t.id], let command = t.write(original) else { continue }
            let ok = (try? await session.shell(command, timeout: .seconds(10)))?.status == 0
            await log("\(t.title) reset to \(original)", ok)
        }
        originals = [:]
        await context.hub.store?.save(originals, as: Self.originalsFile, for: context.device.id)
        await load()
    }

    private func run(_ command: String?, _ done: String) async {
        guard let command, let session = await session() else { status = "Not a valid input"; return }
        let r = try? await session.shell(command, timeout: .seconds(15))
        status = r?.status == 0 ? done : "Failed: \((r?.stdout ?? "") + (r?.stderr ?? ""))".trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openDevTools() async {
        guard let session = await session() else { return }
        busy = true
        defer { busy = false }
        guard let out = try? await session.shell(DevCommands.findVMService, timeout: .seconds(15)),
              let service = DevCommands.vmService(out.stdout) else {
            status = "No Dart VM service in the log buffer: start the Flutter app in debug mode"
            return
        }
        guard let fwd = try? await session.exec(["forward", "tcp:0", "tcp:\(service.port)"], timeout: .seconds(10)), fwd.status == 0,
              let local = Int(fwd.text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let url = URL(string: "http://127.0.0.1:\(local)\(service.path)") else {
            status = "Could not forward the Dart VM service"
            return
        }
        NSWorkspace.shared.open(url)
        status = "DevTools opened on port \(local)"
    }

    private func log(_ what: String, _ ok: Bool) async {
        guard let store = context.hub.store else { return }
        try? await ActionLog.append(device: context.device.name, action: .change(what), result: ok ? .done : .failed("command failed"),
                                    id: context.device.id, store: store)
    }
}
