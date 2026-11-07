//
//  History.swift
//  Hawk
//
//  A bounded record of recent samples, flattened to the numbers the charts draw.
//

import HawkKit
import Foundation

struct Sample: Identifiable {
    let id: Int
    let date: Date
    let cpu, eCPU, pCPU: Double
    let cores: [Double]
    let gpu: Double?
    let socMax, gpuTemp, ssd, battery: Double?
    let power: Double?
    let rx, tx, read, write: Double
    let memoryUsed: Double?
    let pressure: Double?
    let fans: [Double]
}

struct History {
    /// Ten minutes at the fastest interval.
    static let capacity = 1200

    private(set) var samples: [Sample] = []
    private var nextID = 0

    mutating func append(_ s: Snapshot) {
        let memoryUsed = s.memory.map { Double($0.used) / Double(max($0.total, 1)) }
        samples.append(Sample(
            id: nextID, date: s.date,
            cpu: s.cpuTotal, eCPU: s.eUsage, pCPU: s.pUsage, cores: s.cores, gpu: s.gpu,
            socMax: s.socMax, gpuTemp: s.gpuTemp, ssd: s.ssdTemp, battery: s.batteryTemp,
            power: s.systemPower, rx: s.netRx, tx: s.netTx, read: s.diskRead, write: s.diskWrite,
            memoryUsed: memoryUsed, pressure: s.memory?.pressure, fans: s.fans.map(\.actual)))
        nextID += 1
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// Samples from the last `seconds`, thinned to at most `Metrics.maxChartPoints`.
    func window(_ seconds: Double) -> [Sample] {
        guard let last = samples.last else { return [] }
        let start = last.date.addingTimeInterval(-seconds)
        let recent = samples.drop { $0.date < start }
        let stride = Int((Double(recent.count) / Double(Metrics.maxChartPoints)).rounded(.up))
        guard stride > 1 else { return Array(recent) }
        // Keep samples by their id, not their position, so the same ones stay kept as
        // new samples arrive; otherwise the line's shape changes on every tick.
        return recent.filter { $0.id % stride == 0 || $0.id == last.id }
    }

    /// The last `count` values of one core's usage, for its sparkline.
    func core(_ index: Int, last count: Int) -> [Double] {
        samples.suffix(count).map { index < $0.cores.count ? $0.cores[index] : 0 }
    }
}
