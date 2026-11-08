//
//  ScreenSection.swift
//  Hawk
//
//  Mirroring with scrcpy (requirements 10.1) from controls, relaunched in place
//  when an option changes; screenshots and recordings (10.2) with a captures
//  strip and ffmpeg presets.
//

import AppKit
import HawkKit
import SwiftUI

struct ScreenSection: View {
    let context: SectionContext
    @State private var scrcpy: ScrcpyController?
    @State private var captures = CapturesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let scrcpy {
                MirrorCard(context: context, scrcpy: scrcpy, captures: captures)
            }
            CapturesCard(context: context, captures: captures)
        }
        .task(id: context.device.id) {
            let controller = ScrcpyController(device: context.device.id)
            scrcpy = controller
            captures.reload()
            await controller.loadCapabilities()
        }
    }
}

private struct MirrorCard: View {
    let context: SectionContext
    @Bindable var scrcpy: ScrcpyController
    let captures: CapturesModel

    var body: some View {
        Card(title: "Mirror", symbol: "rectangle.on.rectangle") {
            Text(scrcpy.capabilities?.version.map { "scrcpy \($0)" } ?? "").font(Typography.caption).foregroundStyle(Palette.tertiary)
        } content: {
            if !scrcpy.installed {
                Text("scrcpy is not installed: brew install scrcpy").font(Typography.small).foregroundStyle(Palette.secondary)
            } else {
                HStack(spacing: 8) {
                    if scrcpy.running {
                        Button("Stop", systemImage: "stop.fill") { Task { await scrcpy.stop() } }
                    } else {
                        Button("Mirror", systemImage: "play.fill") { Task { await launch() } }.disabled(!context.isLive)
                        Button("Record", systemImage: "record.circle") { Task { await launch(record: true) } }.disabled(!context.isLive)
                        Button("Record without window") { Task { await launch(record: true, recordOnly: true) } }.disabled(!context.isLive)
                    }
                    if scrcpy.recording != nil { Text("Recording").font(Typography.caption).foregroundStyle(Palette.hot) }
                    Spacer()
                }
                .controlSize(.small)
                if let error = scrcpy.error { Text(error).font(Typography.small).foregroundStyle(Palette.hot) }
                OptionsGrid(options: $scrcpy.options, caps: scrcpy.capabilities, locked: scrcpy.recording != nil)
                    .onChange(of: scrcpy.options) { Task { await relaunch() } }
                Text("Live in scrcpy's window: Cmd-F fullscreen, Cmd-Left/Right rotate, Cmd-O screen off, Cmd-Shift-O on, Cmd-G 1:1, Cmd-W resize to fit, Cmd-I FPS.")
                    .font(Typography.caption).foregroundStyle(Palette.tertiary)
            }
        }
    }

    private func adb() async -> String? { await context.hub.server.process()?.executable }

    private func launch(record: Bool = false, recordOnly: Bool = false) async {
        guard let serial = await context.hub.preferredSerial(context.device.id) else { return }
        let file = record ? captures.newFile(device: context.device.name, extension: "mp4") : nil
        scrcpy.start(serial: serial, title: context.device.name, adb: await adb(), record: file, recordOnly: recordOnly)
    }

    private func relaunch() async {
        guard let serial = await context.hub.preferredSerial(context.device.id) else { return }
        await scrcpy.relaunch(serial: serial, title: context.device.name, adb: await adb())
        captures.reload()
    }
}

/// The options; changing one relaunches scrcpy in place (locked while recording).
private struct OptionsGrid: View {
    @Binding var options: ScrcpyOptions
    let caps: ScrcpyCapabilities?
    let locked: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                toggle("Borderless", \.borderless, "window-borderless")
                toggle("On top", \.alwaysOnTop, "always-on-top")
                toggle("Fullscreen", \.fullscreen, "fullscreen")
                toggle("Audio", \.audio, "no-audio")
            }
            GridRow {
                toggle("View only", \.viewOnly, "no-control")
                toggle("Show touches", \.showTouches, "show-touches")
                toggle("Stay awake", \.stayAwake, "stay-awake")
                toggle("Screen off", \.turnScreenOff, "turn-screen-off")
            }
            GridRow {
                Picker("Size", selection: $options.maxSize) {
                    Text("Native").tag(Int?.none)
                    ForEach([1920, 1280, 1024, 800], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                Picker("Bitrate", selection: $options.bitrateMbps) {
                    Text("Default").tag(Int?.none)
                    ForEach([2, 4, 8, 16, 24], id: \.self) { Text("\($0) Mb/s").tag(Int?.some($0)) }
                }
                Picker("FPS", selection: $options.maxFps) {
                    Text("Max").tag(Int?.none)
                    ForEach([15, 30, 60, 120], id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                Picker("Codec", selection: $options.codec) {
                    Text("Default").tag(ScrcpyOptions.Codec?.none)
                    ForEach(ScrcpyOptions.Codec.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag(ScrcpyOptions.Codec?.some($0)) }
                }
            }
        }
        .font(Typography.small)
        .controlSize(.small)
        .disabled(locked)
    }

    @ViewBuilder
    private func toggle(_ title: String, _ key: WritableKeyPath<ScrcpyOptions, Bool>, _ option: String) -> some View {
        if caps?.supports(option) ?? true {
            Toggle(title, isOn: Binding(get: { options[keyPath: key] }, set: { options[keyPath: key] = $0 }))
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }
}

private struct CapturesCard: View {
    let context: SectionContext
    let captures: CapturesModel

    var body: some View {
        Card(title: "Captures", symbol: "camera") {
            Button("Folder...") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { captures.folder = url }
            }
            .buttonStyle(.borderless).font(Typography.caption)
        } content: {
            HStack(spacing: 8) {
                Button("Screenshot", systemImage: "camera.fill") {
                    Task {
                        guard let session = try? await context.hub.session(for: context.device.id) else { return }
                        await captures.screenshot(session: session, device: context.device.name)
                    }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!context.isLive || captures.busy)
                Button("Reveal Folder") { NSWorkspace.shared.open(captures.folder) }
                if captures.busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)
            if let status = captures.status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
            ForEach(captures.files, id: \.self) { url in CaptureRow(url: url, captures: captures) }
        }
    }
}

private struct CaptureRow: View {
    let url: URL
    let captures: CapturesModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: url.pathExtension == "png" ? "photo" : "film").foregroundStyle(Palette.secondary)
            Text(url.lastPathComponent).font(Typography.small).lineLimit(1)
            Spacer()
            if url.pathExtension == "mp4" {
                Menu("Optimize") {
                    ForEach(FFmpegPreset.allCases, id: \.self) { p in Button(p.title) { Task { await captures.optimize(url, preset: p) } } }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
            Button("Reveal", systemImage: "magnifyingglass") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .labelStyle(.iconOnly).accessibilityLabel("Reveal in Finder")
            Button("Delete", systemImage: "trash") { captures.delete(url) }
                .labelStyle(.iconOnly).accessibilityLabel("Move to the Trash")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .draggable(url)
    }
}
