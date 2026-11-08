//
//  LiveSection.swift
//  Hawk
//
//  What the device is doing now (requirements 2.4): CPU per core with its
//  frequency, memory, swap and zram, network rates, temperatures and the top
//  processes. One shell batch every 3 s, only while this page is shown for a live
//  device (LiveSampler decides what each tick reads, inside the phone's budget).
//

import HawkKit
import SwiftUI

struct LiveSection: View {
    let context: SectionContext
    @State private var stats = LiveStats()
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let error, context.isLive { Banner(text: "Could not read the device: \(error)") }
            if !context.isLive {
                ContentUnavailableView("Not connected", systemImage: "waveform.path.ecg", description: Text("Live figures need the device connected."))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Metrics.minCardWidth), spacing: Metrics.spacing, alignment: .top)],
                      alignment: .leading, spacing: Metrics.spacing) {
                LiveCPUCard(stats: stats)
                LiveMemoryCard(stats: stats)
                LiveNetworkCard(stats: stats)
                LiveThermalCard(stats: stats)
                LiveTopCard(stats: stats)
            }
        }
        .task(id: Key(device: context.device.id, live: context.isLive, shown: context.shown)) {
            guard context.isLive, context.shown, let session = try? await context.hub.session(for: context.device.id) else { return }
            var sampler = LiveSampler()
            while !Task.isCancelled {
                do {
                    let parts = try await session.shellBatch(sampler.nextParts, timeout: .seconds(8))
                    let next = sampler.update(parts, now: ProcessInfo.processInfo.systemUptime)
                    if next != stats { stats = next }
                    error = nil
                } catch {
                    self.error = (error as? AdbError)?.summary ?? error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(3), tolerance: .milliseconds(300))
            }
        }
    }

    private struct Key: Equatable { let device: DeviceID; let live: Bool; let shown: Bool }
}

private struct LiveCPUCard: View {
    let stats: LiveStats

    var body: some View {
        Card(title: "CPU", symbol: "cpu") {
            Text(stats.total.map { Format.percent($0) } ?? "-").font(Typography.caption).foregroundStyle(Palette.secondary)
        } content: {
            ForEach(Array(stats.cores.enumerated()), id: \.offset) { i, share in
                HStack(spacing: 8) {
                    Text("\(i)").font(Typography.caption).foregroundStyle(Palette.tertiary).frame(width: 16, alignment: .trailing)
                    MeterBar(value: share, color: Palette.load(share))
                    Text(stats.frequencyMHz[i].map { "\($0) MHz" } ?? "").font(Typography.caption).foregroundStyle(Palette.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
            }
        }
    }
}

private struct LiveMemoryCard: View {
    let stats: LiveStats

    var body: some View {
        Card(title: "Memory", symbol: "memorychip") {
            if let total = stats.memTotalKB, let available = stats.memAvailableKB, total > 0 {
                let used = Double(total - available) / Double(total)
                Text("\(Format.bytes(Double(total - available) * 1024)) used of \(Format.bytes(Double(total) * 1024))").font(Typography.small)
                MeterBar(value: used, color: Palette.load(used))
            }
            if let total = stats.swapTotalKB, let free = stats.swapFreeKB, total > 0 {
                Text("Swap and zram: \(Format.bytes(Double(total - free) * 1024)) of \(Format.bytes(Double(total) * 1024))").font(Typography.small)
                MeterBar(value: Double(total - free) / Double(total), color: Palette.memCompressed)
            }
        }
    }
}

private struct LiveNetworkCard: View {
    let stats: LiveStats

    var body: some View {
        Card(title: "Network", symbol: "network") {
            HStack(spacing: 24) {
                LegendValue(color: Palette.download, label: "Down", value: stats.rxRate.map { Format.rate($0) } ?? "-")
                LegendValue(color: Palette.upload, label: "Up", value: stats.txRate.map { Format.rate($0) } ?? "-")
            }
        }
    }
}

private struct LiveThermalCard: View {
    let stats: LiveStats

    var body: some View {
        Card(title: "Temperatures", symbol: "thermometer.medium") {
            if stats.temperatures.isEmpty { Text("-").font(Typography.small).foregroundStyle(Palette.secondary) }
            ForEach(stats.temperatures, id: \.name) { t in
                HStack {
                    Text(t.name).font(Typography.small)
                    Spacer()
                    Text(String(format: "%.1f °C", t.celsius)).font(Typography.small).foregroundStyle(Palette.heat(t.celsius))
                }
            }
        }
    }
}

private struct LiveTopCard: View {
    let stats: LiveStats

    var body: some View {
        Card(title: "Top processes", symbol: "list.number") {
            ForEach(stats.top, id: \.pid) { p in
                HStack {
                    Text(p.name).font(Typography.small).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.1f%%", p.cpu)).font(Typography.small).monospacedDigit()
                    Text(p.resident).font(Typography.caption).foregroundStyle(Palette.secondary).frame(width: 56, alignment: .trailing)
                }
            }
        }
    }
}
