//
//  CaptureView.swift
//  Hawk
//
//  Request capture (requirements 7.4, level 2), a part of the Network page: a
//  proxy on this Mac reached through adb reverse, the phone's proxy pointed at it,
//  hosts and bytes listed. The phone's own proxy is saved before Hawk changes it
//  and put back on Stop, when the page closes, and on the next connection after
//  an unplug or a crash (ProxyRestore). HTTPS is tunnelled, not decrypted.
//

import AppKit
import HawkKit
import SwiftUI

struct CaptureView: View {
    let context: SectionContext
    @State private var proxy: CaptureProxy?
    @State private var port: UInt16?
    @State private var requests: [CapturedRequest] = []
    @State private var status: String?
    @State private var busy = false

    var body: some View {
        Card(title: "Request capture", symbol: "dot.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: 8) {
                if port != nil {
                    Banner(text: "The phone's proxy points at Hawk. Stop puts the phone's own setting back.")
                }
                HStack {
                    if port == nil {
                        Button("Start capture", systemImage: "record.circle") { Task { await start() } }.disabled(!context.isLive || busy)
                    } else {
                        Button("Stop", systemImage: "stop.fill") { Task { await stop() } }.disabled(busy)
                        Button("Clear") { Task { await proxy?.clear() } }
                    }
                    if busy { ProgressView().controlSize(.small) }
                    Text("Hosts and bytes of apps that use the system proxy; HTTPS content is not decrypted. Flutter apps ignore the system proxy unless the app sets one.")
                        .font(Typography.caption).foregroundStyle(Palette.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .controlSize(.small)
                if let status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
                if !requests.isEmpty {
                    DataTable(columns: Self.columns, rows: requests, sortKey: "time", menu: nil, onSelect: nil).frame(minHeight: 220)
                }
            }
        }
        .onDisappear { Task { await stop() } }
    }

    static let columns: [Column<CapturedRequest>] = [
        Column(id: "time", title: "Time", width: 80, text: { $0.start.formatted(date: .omitted, time: .standard) }, less: { $0.start < $1.start }),
        Column(id: "method", title: "Method", width: 70, numeric: false, text: { $0.method == "CONNECT" ? "HTTPS" : $0.method },
               less: { $0.method < $1.method }),
        Column(id: "host", title: "Host", width: 240, flexible: true, numeric: false, text: { "\($0.host)\($0.port == 80 || $0.port == 443 ? "" : ":\($0.port)")" },
               tooltip: { $0.path }, less: { $0.host < $1.host }),
        Column(id: "status", title: "Status", width: 56, text: { $0.status.map(String.init) ?? "-" }, less: { ($0.status ?? 0) < ($1.status ?? 0) }),
        Column(id: "up", title: "Sent", width: 70, text: { Format.bytes(Double($0.up)) }, less: { $0.up < $1.up }),
        Column(id: "down", title: "Received", width: 80, text: { Format.bytes(Double($0.down)) }, less: { $0.down < $1.down }),
        Column(id: "duration", title: "Time open", width: 70, text: { $0.duration.map { String(format: "%.1f s", $0) } ?? "open" },
               less: { ($0.duration ?? .infinity) < ($1.duration ?? .infinity) }),
    ]

    private func start() async {
        guard let session = try? await context.hub.session(for: context.device.id) else { return }
        busy = true
        defer { busy = false }
        let p = CaptureProxy()
        do {
            let port = try await p.start()
            guard let reverse = try? await session.exec(["reverse", "tcp:\(port)", "tcp:\(port)"], timeout: .seconds(10)), reverse.status == 0 else {
                await p.stop()
                status = "Could not open the tunnel to the phone"
                return
            }
            // The phone's own value is saved before anything changes.
            let current = try await session.shell(ProxyRestore.read, timeout: .seconds(10))
            let record = ProxyRestore(original: ProxyRestore.normalise(current.stdout), set: "127.0.0.1:\(port)")
            await context.hub.store?.save(record, as: ProxyRestore.file, for: context.device.id)
            await context.hub.store?.flush()
            guard let set = ProxyRestore.setCommand(record.set), (try? await session.shell(set, timeout: .seconds(10)))?.status == 0 else {
                await ProxyRestore.restoreIfNeeded(on: session, deviceName: context.device.name, store: context.hub.store)
                await p.stop()
                status = "Could not set the phone's proxy"
                return
            }
            if let store = context.hub.store {
                try? await ActionLog.append(device: context.device.name, action: .change("Proxy set to Hawk (\(record.set)), was \(record.original ?? "none")"),
                                            result: .done, id: context.device.id, store: store)
            }
            proxy = p
            self.port = port
            status = nil
            Task {
                for await list in p.updates { requests = list }
            }
        } catch {
            await p.stop()
            status = "Capture failed: \(error.localizedDescription)"
        }
    }

    private func stop() async {
        guard let p = proxy, let port else { return }
        proxy = nil
        self.port = nil
        if let session = try? await context.hub.session(for: context.device.id) {
            await ProxyRestore.restoreIfNeeded(on: session, deviceName: context.device.name, store: context.hub.store)
            _ = try? await session.exec(["reverse", "--remove", "tcp:\(port)"], timeout: .seconds(10))
        }
        await p.stop()
    }
}
