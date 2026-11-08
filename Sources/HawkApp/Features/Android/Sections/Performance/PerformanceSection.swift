//
//  PerformanceSection.swift
//  Hawk
//
//  Performance (requirements 9), on demand: a capture samples CPU frequency,
//  pressure (CPU, memory, I/O), thermal status and the app's memory every second
//  and lays them on one time axis, so "jank at 12:03 while the CPU throttled" is
//  visible; frame stats for the app when it stops. A Perfetto trace can be saved
//  for deeper analysis. Nothing runs until Start; it stops on its own after 10 min.
//

import AppKit
import HawkKit
import SwiftUI

struct PerformanceSection: View {
    let context: SectionContext
    @State private var apps: [(name: String, title: String)] = []
    @State private var package = ""
    @State private var samples: [PerfSample] = []
    @State private var frames: FrameStats?
    @State private var capturing = false
    @State private var capture: Task<Void, Never>?
    @State private var status: String?
    @State private var tracing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Picker("App", selection: $package) {
                    Text("Whole device").tag("")
                    ForEach(apps, id: \.name) { Text($0.title).tag($0.name) }
                }
                .frame(maxWidth: 320).disabled(capturing)
                if capturing {
                    Button("Stop", systemImage: "stop.fill") { stop() }
                } else {
                    Button("Start capture", systemImage: "record.circle") { start() }.disabled(!context.isLive)
                }
                Button("Perfetto trace (10 s)...") { Task { await trace() } }.disabled(!context.isLive || tracing || capturing)
                if tracing { ProgressView().controlSize(.small) }
                Spacer()
            }
            .controlSize(.small)
            if let status { Text(status).font(Typography.small).foregroundStyle(Palette.secondary) }
            Card(title: "Timeline", symbol: "chart.xyaxis.line") {
                Text(samples.last.map { String(format: "%.0f s", $0.t) } ?? "").font(Typography.caption).foregroundStyle(Palette.tertiary)
            } content: {
                TimelineChart(samples: samples).frame(height: 220)
                HStack(spacing: 16) {
                    legend("CPU max MHz", Palette.pCore)
                    legend("CPU pressure", Palette.hot)
                    legend("Memory pressure", Palette.memCompressed)
                    legend("I/O pressure", Palette.diskWrite)
                    legend("Thermal", Palette.warn)
                }
                if let pss = samples.last(where: { $0.pssKB != nil })?.pssKB {
                    Text("App memory now: \(Format.bytes(Double(pss) * 1024)) PSS").font(Typography.small).foregroundStyle(Palette.secondary)
                }
            }
            if let f = frames, f.total != nil {
                Card(title: "Frames", symbol: "film") {
                    Text("\(f.total ?? 0) frames, \(f.janky ?? 0) janky (\(Format.percent(f.jankyShare ?? 0))). 50th \(f.p50.map { "\(Int($0)) ms" } ?? "-"), 90th \(f.p90.map { "\(Int($0)) ms" } ?? "-"), 95th \(f.p95.map { "\(Int($0)) ms" } ?? "-"), 99th \(f.p99.map { "\(Int($0)) ms" } ?? "-")")
                        .font(Typography.small)
                }
            }
        }
        .task(id: context.device.id) {
            if let index = await context.hub.packages(for: context.device.id) {
                apps = index.packages.values.filter { !$0.isSystem }.map { ($0.name, $0.label ?? $0.name) }.sorted { $0.title < $1.title }
            }
        }
        .onDisappear { stop() }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title).font(Typography.caption).foregroundStyle(Palette.secondary)
        }
    }

    private func start() {
        samples = []
        frames = nil
        capturing = true
        let pkg = package.isEmpty ? nil : package
        let hub = context.hub, id = context.device.id
        capture = Task {
            guard let session = try? await hub.session(for: id) else { capturing = false; return }
            if let reset = pkg.flatMap({ PerformanceCapture.gfxinfo($0, reset: true) }) { _ = try? await session.shell(reset, timeout: .seconds(10)) }
            let started = ProcessInfo.processInfo.systemUptime
            var tick = 0
            while !Task.isCancelled, tick < PerformanceCapture.maxSeconds {
                if let parts = try? await session.shellBatch(PerformanceCapture.parts(tick: tick, package: pkg), timeout: .seconds(5)) {
                    samples.append(PerformanceCapture.sample(parts, t: ProcessInfo.processInfo.systemUptime - started))
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1), tolerance: .milliseconds(100))
            }
            if let read = pkg.flatMap({ PerformanceCapture.gfxinfo($0, reset: false) }), let out = try? await session.shell(read, timeout: .seconds(10)) {
                frames = FrameStats.parse(out.stdout)
            }
            capturing = false
        }
    }

    private func stop() {
        capture?.cancel()
        capture = nil
    }

    private func trace() async {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(context.device.name)-trace.perfetto-trace"
        guard panel.runModal() == .OK, let url = panel.url, let session = try? await context.hub.session(for: context.device.id) else { return }
        tracing = true
        defer { tracing = false }
        status = "Recording a 10 s Perfetto trace"
        let out = try? await session.shell(PerformanceCapture.traceCommand(seconds: 10), timeout: .seconds(40))
        do {
            try await session.pull(PerformanceCapture.traceRemote, to: url, timeout: .seconds(120))
            status = "Saved \(url.lastPathComponent): open it at ui.perfetto.dev"
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            status = "Perfetto failed: \(out?.stdout.split(separator: "\n").last.map(String.init) ?? (error as? AdbError)?.summary ?? "no trace")"
        }
        _ = try? await session.shell("rm -f \(PerformanceCapture.traceRemote)", timeout: .seconds(10))
    }
}

/// The series on one time axis, each as a share of its own range; at most
/// Metrics.maxChartPoints points per series.
private struct TimelineChart: View {
    let samples: [PerfSample]

    var body: some View {
        Canvas { ctx, size in
            guard samples.count > 1, let last = samples.last?.t, last > 0 else { return }
            let maxMHz = Double(samples.compactMap(\.maxMHz).max() ?? 1)
            let series: [([(t: Double, v: Double)], Color)] = [
                (samples.compactMap { s in s.maxMHz.map { (s.t, Double($0) / max(maxMHz, 1)) } }, Palette.pCore),
                (samples.compactMap { s in s.cpuPressure.map { (s.t, $0) } }, Palette.hot),
                (samples.compactMap { s in s.memoryPressure.map { (s.t, $0) } }, Palette.memCompressed),
                (samples.compactMap { s in s.ioPressure.map { (s.t, $0) } }, Palette.diskWrite),
                (samples.compactMap { s in s.thermal.map { (s.t, Double($0) / 6) } }, Palette.warn),
            ]
            for (points, color) in series {
                let pts = Timeline.downsample(points, max: Metrics.maxChartPoints)
                guard pts.count > 1 else { continue }
                var path = Path()
                for (i, p) in pts.enumerated() {
                    let pt = CGPoint(x: size.width * p.t / last, y: size.height * (1 - min(max(p.v, 0), 1)))
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.5)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Palette.track.opacity(0.4)))
        .accessibilityLabel("Performance timeline")
    }
}
