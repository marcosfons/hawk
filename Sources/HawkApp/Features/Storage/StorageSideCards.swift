//
//  StorageSideCards.swift
//  Hawk
//
//  WhatsApp (measured, never deleted) and Docker (what each volume is used by).
//

import HawkKit
import SwiftUI

struct WhatsAppCard: View {
    @Environment(StorageModel.self) private var storage

    static let kindColors: [String: Color] = ["Videos": Palette.upload, "Photos": Palette.accent, "Audio": Palette.eCore,
                                              "Documents": Palette.warn, "Other": Palette.memCached]

    var body: some View {
        let report = storage.whatsapp
        Card(title: "WhatsApp", symbol: "message.fill") {
            HStack(spacing: 8) {
                if storage.whatsappBusy { ProgressView().controlSize(.small) }
                if let report { Text(Format.bytes(Double(report.totalBytes))).font(Typography.value) }
            }
        } content: {
            Label("Measured only. Hawk never deletes WhatsApp data.", systemImage: "lock.fill")
                .font(Typography.caption).foregroundStyle(Palette.secondary)
            if let report {
                let total = Double(max(report.totalBytes, 1))
                StackedBar(segments: WhatsAppAnalyzer.kinds.map {
                    .init(id: $0, fraction: Double(report.bytes(ofKind: $0)) / total, color: Self.kindColors[$0] ?? Palette.track)
                })
                Grid(horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(WhatsAppAnalyzer.kinds.prefix(3), id: \.self) { k in
                            LegendValue(color: Self.kindColors[k] ?? Palette.track, label: k, value: Format.bytes(Double(report.bytes(ofKind: k))))
                        }
                    }
                    GridRow {
                        ForEach(WhatsAppAnalyzer.kinds.dropFirst(3), id: \.self) { k in
                            LegendValue(color: Self.kindColors[k] ?? Palette.track, label: k, value: Format.bytes(Double(report.bytes(ofKind: k))))
                        }
                    }
                }
                let top = Double(report.chats.first?.bytes ?? 1)
                VStack(spacing: 6) {
                    ForEach(report.chats.prefix(12)) { chat in
                        ChatRow(chat: chat, fraction: Double(chat.bytes) / max(top, 1))
                    }
                }
                HStack {
                    Text("\(report.chats.count) chats - updated \(Format.ago(report.measuredAt)) - \(report.rewalked) re-counted")
                        .font(Typography.caption).foregroundStyle(Palette.tertiary)
                    Spacer()
                    Button("Update") { storage.refreshWhatsApp() }.controlSize(.small).disabled(storage.whatsappBusy)
                }
            } else if storage.whatsappNoAccess {
                Text("Needs Full Disk Access to read WhatsApp's folders.").font(Typography.label).foregroundStyle(Palette.warn)
            } else if !storage.whatsappBusy {
                Text("WhatsApp media not found.").font(Typography.label).foregroundStyle(Palette.secondary)
            }
        }
    }
}

private struct ChatRow: View {
    let chat: WhatsAppChat
    let fraction: Double

    var body: some View {
        let quiet = chat.lastMessage.map { Date().timeIntervalSince($0) > 180 * 86400 } ?? false
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(chat.displayName).font(Typography.small).lineLimit(1)
                if quiet {
                    Text("quiet").font(Typography.caption).foregroundStyle(Palette.warn)
                        .padding(.horizontal, 5).background(Capsule().fill(Palette.warn.opacity(0.15)))
                        .help("No messages for over six months")
                }
                Spacer(minLength: 6)
                Text("\(chat.files) files - last message \(Format.ago(chat.lastMessage))")
                    .font(Typography.caption).foregroundStyle(Palette.tertiary).lineLimit(1)
                Text(Format.bytes(Double(chat.bytes))).font(Typography.small).frame(width: 60, alignment: .trailing)
            }
            StackedBar(segments: WhatsAppAnalyzer.kinds.map {
                .init(id: $0, fraction: fraction * Double(chat.byKind[$0] ?? 0) / Double(max(chat.bytes, 1)),
                      color: WhatsAppCard.kindColors[$0] ?? Palette.track)
            }, height: 4)
        }
    }
}

struct DockerCard: View {
    @Environment(StorageModel.self) private var storage

    var body: some View {
        let docker = storage.docker
        let vm = storage.entry("docker-vm-disk")
        Card(title: "Docker", symbol: "shippingbox.fill") {
            if let vm { Text("VM disk \(Format.bytes(Double(vm.sizeBytes ?? 0)))").font(Typography.value) }
        } content: {
            if docker == nil {
                ProgressView().controlSize(.small)
            } else if docker?.running == false {
                Label("Docker is not running. Figures below are from the last scan.", systemImage: "moon.zzz")
                    .font(Typography.label).foregroundStyle(Palette.secondary)
                ForEach(["docker-images", "docker-volumes", "docker-build-cache", "docker-containers"], id: \.self) { id in
                    if let e = storage.entry(id) {
                        LegendValue(color: e.risk.color, label: e.name, value: Format.bytes(Double(e.sizeBytes ?? 0)))
                    }
                }
            } else if let docker {
                let runningCount = docker.containers.filter(\.running).count
                Text("\(docker.containers.count) containers, \(runningCount) running - \(docker.volumes.count) volumes")
                    .font(Typography.label).foregroundStyle(Palette.secondary)
                VStack(spacing: 6) {
                    ForEach(docker.volumes.sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }.prefix(20)) { volume in
                        VolumeRow(volume: volume)
                    }
                }
            }
            Text("Removing data inside Docker frees space in its VM. The host disk image only shrinks with a disk resize or reset in Docker Desktop.")
                .font(Typography.caption).foregroundStyle(Palette.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VolumeRow: View {
    let volume: DockerState.Volume
    @Environment(StorageModel.self) private var storage

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(volume.inUse ? Palette.good : volume.containers.isEmpty ? Palette.warn : Palette.secondary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name).font(Typography.small).lineLimit(1).truncationMode(.middle)
                Text(status).font(Typography.caption).foregroundStyle(Palette.tertiary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(volume.bytes.map { Format.bytes(Double($0)) } ?? "-").font(Typography.small).frame(width: 60, alignment: .trailing)
            if volume.containers.isEmpty {
                Button { storage.requestVolumeRemoval(volume) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(Palette.secondary)
                    .disabled(storage.working.contains("vol:" + volume.name))
                    .help("Remove this unused volume…")
                    .accessibilityLabel("Remove volume \(volume.name)")
            } else {
                Image(systemName: "lock.fill").foregroundStyle(Palette.tertiary)
                    .help("Used by a container: remove the container first")
            }
        }
    }

    private var status: String {
        if volume.inUse { return "in use by \(volume.runningContainers.joined(separator: ", "))" }
        if !volume.containers.isEmpty {
            return "used by stopped \(volume.containers.joined(separator: ", ")) - last active \(Format.ago(volume.lastActive))"
        }
        return "not used by any container"
    }
}
