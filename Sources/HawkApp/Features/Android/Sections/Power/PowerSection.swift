//
//  PowerSection.swift
//  Hawk
//
//  Background and power (requirements 14.1): why an app may stop working in the
//  background (battery exemption, standby bucket, app ops, location permission,
//  what it holds now), and states forced to test without waiting hours, each
//  with its undo; anything still forced is undone when the device comes back.
//

import HawkKit
import SwiftUI

struct PowerSection: View {
    let context: SectionContext
    @State private var apps: [(name: String, title: String)] = []
    @State private var package = ""
    @State private var state: AppPowerState?
    @State private var forced: [PowerForce] = []
    @State private var busy = false
    @State private var bucket = 45

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            Card(title: "App in the background", symbol: "battery.75percent") {
                HStack {
                    Picker("App", selection: $package) {
                        Text("Choose an app").tag("")
                        ForEach(apps, id: \.name) { Text($0.title).tag($0.name) }
                    }
                    .frame(maxWidth: 360)
                    Button("Read", systemImage: "arrow.clockwise") { Task { await read() } }.disabled(package.isEmpty || !context.isLive || busy)
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                .controlSize(.small)
                if let s = state { StateGrid(state: s) }
            }
            Card(title: "Force a state", symbol: "bolt.badge.clock") {
                HStack(spacing: 8) {
                    Button("Force Doze") { Task { await apply(.doze) } }
                    Button("Unplug battery") { Task { await apply(.unplugBattery) } }
                    Divider().frame(height: 18)
                    Picker("Bucket", selection: $bucket) {
                        ForEach([10, 20, 30, 40, 45], id: \.self) { b in Text(AppPowerState(bucket: b).bucketName ?? "\(b)").tag(b) }
                    }
                    .frame(width: 170)
                    Button("Set bucket") {
                        Task { await apply(.standbyBucket(package: package, to: bucket, from: state?.bucket ?? 10)) }
                    }
                    .disabled(package.isEmpty || state?.bucket == nil)
                    Button("Make inactive") { Task { await apply(.inactive(package: package)) } }.disabled(package.isEmpty)
                }
                .controlSize(.small)
                .disabled(!context.isLive || busy)
                if forced.isEmpty {
                    Text("Nothing forced.").font(Typography.small).foregroundStyle(Palette.secondary)
                } else {
                    ForEach(forced, id: \.self) { f in
                        HStack {
                            Text(f.title).font(Typography.small)
                            Spacer()
                            Button("Undo") { Task { await undo(f) } }.controlSize(.small).disabled(!context.isLive)
                        }
                    }
                    Button("Undo all") { Task { await undoAll() } }.controlSize(.small).disabled(!context.isLive)
                    Text("Anything still forced is undone when the device comes back after a disconnect.")
                        .font(Typography.caption).foregroundStyle(Palette.tertiary)
                }
            }
        }
        .task(id: context.device.id) {
            if let index = await context.hub.packages(for: context.device.id) {
                apps = index.packages.values.filter { !$0.isSystem }.map { ($0.name, $0.label ?? $0.name) }.sorted { $0.title < $1.title }
            }
            forced = await PowerForces.load(context.device.id, store: context.hub.store)
        }
        .onChange(of: package) { state = nil; Task { await read() } }
    }

    private func session() async -> (any DeviceSession)? { try? await context.hub.session(for: context.device.id) }

    private func read() async {
        guard let parts = AppPowerState.parts(package), let session = await session() else { return }
        busy = true
        defer { busy = false }
        let pkg = package
        if let out = try? await session.shellBatch(parts, timeout: .seconds(30)), pkg == package {
            state = AppPowerState.parse(out, package: pkg)
        }
    }

    private func apply(_ f: PowerForce) async {
        guard let session = await session() else { return }
        busy = true
        defer { busy = false }
        _ = await PowerForces.apply(f, on: session, deviceName: context.device.name, store: context.hub.store)
        forced = await PowerForces.load(context.device.id, store: context.hub.store)
        if !package.isEmpty { await read() }
    }

    private func undo(_ f: PowerForce) async {
        guard let session = await session() else { return }
        await PowerForces.undo(f, on: session, deviceName: context.device.name, store: context.hub.store)
        forced = await PowerForces.load(context.device.id, store: context.hub.store)
    }

    private func undoAll() async {
        guard let session = await session() else { return }
        await PowerForces.undoAll(on: session, deviceName: context.device.name, store: context.hub.store)
        forced = await PowerForces.load(context.device.id, store: context.hub.store)
    }
}

private struct StateGrid: View {
    let state: AppPowerState

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
            row("Battery optimisation", state.exemption.map { "Exempt (\($0))" } ?? "Optimised")
            row("Standby bucket", state.bucketName)
            row("Location", [state.fineLocation == true ? "precise" : nil, state.coarseLocation == true ? "approximate" : nil,
                             state.backgroundLocation == true ? "all the time" : (state.fineLocation == true || state.coarseLocation == true ? "while in use" : nil)]
                .compactMap { $0 }.joined(separator: ", ").nilIfEmpty ?? "Not granted")
            ForEach(state.appOps.keys.sorted(), id: \.self) { op in row(op, state.appOps[op]) }
            row("Holding now", "\(state.locationRequests) location, \(state.wakelocks) wakelocks, \(state.alarms) alarms, \(state.foregroundServices) foreground services")
        }
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).font(Typography.caption).foregroundStyle(Palette.tertiary).gridColumnAlignment(.trailing)
            Text(value ?? "-").font(Typography.small).textSelection(.enabled)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension AppPowerState {
    init(bucket: Int) {
        self.init()
        self.bucket = bucket
    }
}
