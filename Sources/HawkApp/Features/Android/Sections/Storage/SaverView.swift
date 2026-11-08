//
//  SaverView.swift
//  Hawk
//
//  Storage saver (requirements 6.1), part of the Storage page: the phone's
//  biggest videos from its media store, what re-encoding would free, and a
//  guided run that archives to the Mac and/or puts a smaller copy back. Every
//  step obeys SaverRules (WhatsApp media never; nothing deleted before the copy
//  passed its check and the original is archived or its loss confirmed).
//

import AppKit
import HawkKit
import SwiftUI

struct SaverView: View {
    let context: SectionContext
    @State private var videos: [PhoneVideo] = []
    @State private var chosen: Set<Int> = []
    @State private var minSide = 1900
    @State private var maxSide = 1920
    @State private var mode: SaverWorker.Mode = .both
    @State private var archive: URL?
    @State private var acceptLoss = false
    @State private var confirming = false
    @State private var running = false
    @State private var status: String?

    private var shown: [PhoneVideo] {
        Array(videos.filter { $0.longSide >= minSide && SaverRules.mayTouch($0.path).isAllowed }.prefix(60))
    }
    private var selection: [PhoneVideo] { shown.filter { chosen.contains($0.id) } }

    var body: some View {
        Card(title: "Storage saver", symbol: "film.stack") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button(videos.isEmpty ? "Find big videos" : "Find again") { Task { await find() } }.disabled(!context.isLive || running)
                    Picker("Show", selection: $minSide) {
                        Text("1080p and up").tag(1900)
                        Text("4K").tag(3800)
                        Text("All").tag(0)
                    }
                    .fixedSize()
                    Picker("Re-encode to", selection: $maxSide) {
                        Text("1080p").tag(1920)
                        Text("720p").tag(1280)
                    }
                    .fixedSize()
                    Spacer()
                }
                .controlSize(.small)
                if let status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
                ForEach(shown) { v in
                    Toggle(isOn: Binding(get: { chosen.contains(v.id) }, set: { if $0 { chosen.insert(v.id) } else { chosen.remove(v.id) } })) {
                        HStack {
                            Text(v.name).font(Typography.small).lineLimit(1)
                            Spacer()
                            Text("\(v.width)x\(v.height) - \(v.duration / 60000) min - \(Format.bytes(Double(v.size)))").font(Typography.caption)
                                .foregroundStyle(Palette.secondary)
                        }
                    }
                }
                if !selection.isEmpty {
                    Divider()
                    Text("\(selection.count) videos, \(Format.bytes(Double(selection.reduce(0) { $0 + $1.size })))"
                         + (mode == .archive ? "" : ", about \(Format.bytes(Double(SaverEstimate.saving(selection, maxLongSide: maxSide)))) freed by re-encoding"))
                        .font(Typography.label)
                    Picker("What happens", selection: $mode) {
                        ForEach(SaverWorker.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    HStack {
                        Button(archive.map { "Archive to \($0.lastPathComponent)" } ?? "Choose archive folder...") { chooseArchive() }
                            .disabled(mode == .reencode)
                        if mode == .reencode {
                            Toggle("I accept losing the originals", isOn: $acceptLoss)
                        }
                    }
                    .controlSize(.small)
                    Button("Run on \(selection.count) videos") { confirming = true }
                        .disabled(running || !context.isLive || (mode != .reencode && archive == nil) || (mode == .reencode && !acceptLoss)
                                  || (mode != .archive && !SaverWorker.canReencode))
                    if mode != .archive, !SaverWorker.canReencode { Text("Re-encoding needs ffmpeg: brew install ffmpeg").font(Typography.caption).foregroundStyle(Palette.warn) }
                }
            }
        }
        .confirmationDialog("Change \(selection.count) videos on the phone?", isPresented: $confirming) {
            Button("Run", role: .destructive) { Task { await run() } }
        } message: {
            Text(mode == .reencode ? "Each original is replaced by its smaller copy once the copy passes its check. The originals are not kept."
                                   : "Each original is copied to the Mac and checked before anything on the phone changes.")
        }
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Archive Here"
        if panel.runModal() == .OK { archive = panel.url }
    }

    private func find() async {
        guard let session = try? await context.hub.session(for: context.device.id) else { return }
        status = "Reading the media store"
        guard let out = try? await session.shell(PhoneVideo.query, timeout: .seconds(60)) else { status = "Could not read the media store"; return }
        videos = await Task.detached(priority: .utility) { PhoneVideo.parse(out.stdout) }.value
        chosen = []
        status = "\(videos.count) videos, \(Format.bytes(Double(videos.reduce(0) { $0 + $1.size }))) in all"
    }

    private func run() async {
        guard let session = try? await context.hub.session(for: context.device.id) else { return }
        running = true
        defer { running = false }
        var freed: Int64 = 0, done = 0
        let batch = selection
        for (i, v) in batch.enumerated() {
            status = "\(i + 1) of \(batch.count): \(v.name)"
            let out = await SaverWorker.run(v, mode: mode, maxLongSide: maxSide, archive: archive, confirmedLoss: mode == .reencode && acceptLoss,
                                            session: session, deviceName: context.device.name, store: context.hub.store)
            if out.note == "Done" { done += 1; freed += out.freed } else { status = "\(v.name): \(out.note)" }
        }
        status = "\(done) of \(batch.count) done, \(Format.bytes(Double(freed))) freed"
        await find()
    }
}
