//
//  ShellSection.swift
//  Hawk
//
//  A shell on the device (requirements 10.3): the user's own terminal opened with
//  `adb -s <serial> shell` ready (a .command file opened with the system, so no
//  Automation permission), and quick commands: saved one-liners, per device or
//  for every device, whose output shows here.
//

import AppKit
import HawkKit
import SwiftUI

struct QuickCommand: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var command: String
    /// nil: every device.
    var device: String?
}

struct ShellSection: View {
    let context: SectionContext
    @State private var commands: [QuickCommand] = []
    @State private var output = ""
    @State private var running = false
    @State private var newName = ""
    @State private var newCommand = ""
    @State private var forThisDevice = true
    @State private var everyDevice = false

    private static let key = "androidQuickCommands"

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Card(title: "Shell", symbol: "terminal") {
                HStack {
                    Button("Open in Terminal", systemImage: "terminal") { Task { await openTerminal() } }.disabled(!context.isLive)
                    Text("Opens your terminal with an adb shell on this device.").font(Typography.caption).foregroundStyle(Palette.secondary)
                    Spacer()
                }
                .controlSize(.small)
            }
            Card(title: "Quick commands", symbol: "bolt") {
                Toggle("Run on every connected device", isOn: $everyDevice).controlSize(.small)
                ForEach(visible) { c in
                    HStack {
                        Button(c.name) { Task { await run(c) } }.disabled(!context.isLive || running)
                        Text(c.command).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.secondary).lineLimit(1)
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { remove(c) }.labelStyle(.iconOnly).buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(c.name)")
                    }
                    .controlSize(.small)
                }
                HStack {
                    TextField("Name", text: $newName).frame(width: 140)
                    TextField("Command, e.g. dumpsys battery | head", text: $newCommand).font(.system(size: 11, design: .monospaced))
                    Toggle("Save for this device only", isOn: $forThisDevice)
                    Button("Add") { add() }.disabled(newName.isEmpty || newCommand.isEmpty)
                }
                .controlSize(.small).textFieldStyle(.roundedBorder)
                if running || !output.isEmpty {
                    ScrollView {
                        Text(running ? "Running..." : output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
            }
        }
        .onAppear { load() }
    }

    private var deviceKey: String { DeviceStore.folderName(context.device.id) }
    private var visible: [QuickCommand] { commands.filter { $0.device == nil || $0.device == deviceKey } }

    private func load() {
        commands = UserDefaults.standard.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([QuickCommand].self, from: $0) } ?? [
            QuickCommand(name: "Battery", command: "dumpsys battery"),
            QuickCommand(name: "Top", command: "top -b -n 1 | head -20"),
            QuickCommand(name: "Focused window", command: "dumpsys window displays | grep -m1 mCurrentFocus"),
        ]
    }

    private func save() {
        if let data = try? JSONEncoder().encode(commands) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private func add() {
        commands.append(QuickCommand(name: String(newName.prefix(40)), command: String(newCommand.prefix(2000)), device: forThisDevice ? deviceKey : nil))
        newName = ""
        newCommand = ""
        save()
    }

    private func remove(_ c: QuickCommand) {
        commands.removeAll { $0.id == c.id }
        save()
    }

    private func run(_ c: QuickCommand) async {
        running = true
        defer { running = false }
        if everyDevice {
            var parts: [String] = []
            for d in await context.hub.devices().filter({ $0.state == .device }).sorted(by: { $0.name < $1.name }) {
                let r = try? await context.hub.session(for: d.id).shell(c.command, timeout: .seconds(30))
                parts.append("== \(d.name)\n" + (r.map { $0.stdout + $0.stderr } ?? "(no answer)"))
            }
            output = String(parts.joined(separator: "\n").prefix(200_000))
            return
        }
        do {
            let r = try await context.hub.session(for: context.device.id).shell(c.command, timeout: .seconds(30))
            let text = r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)
            output = String(text.prefix(200_000)) + (r.status == 0 ? "" : "\n(exit \(r.status))")
        } catch {
            output = (error as? AdbError)?.summary ?? error.localizedDescription
        }
    }

    /// A .command file with the adb path and serial quoted, opened with the system.
    private func openTerminal() async {
        guard let adb = await context.hub.server.process()?.executable,
              let serial = await context.hub.preferredSerial(context.device.id), ShellQuote.isSerial(serial) else { return }
        let url = FileManager.default.temporaryDirectory.appending(path: "hawk-shell-\(DeviceStore.folderName(context.device.id)).command")
        let script = "#!/bin/sh\nclear\nexec \(ShellQuote.quote(adb)) -s \(ShellQuote.quote(serial)) shell\n"
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {
            output = "Could not open a terminal: \(error.localizedDescription)"
        }
    }
}
