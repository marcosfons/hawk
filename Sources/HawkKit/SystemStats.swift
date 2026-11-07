import Darwin
import Foundation
import IOKit

// MARK: - CPU

/// Per-core usage from mach tick counters. Call `sample()` repeatedly; usage is the delta between calls.
public final class CPUMonitor {
    private var last: [[UInt32]] = []
    /// Number of efficiency cores. On Apple Silicon they are logical CPUs 0..<eCores.
    public let eCores: Int = { var n: Int32 = 0, s = 4; sysctlbyname("hw.perflevel1.logicalcpu", &n, &s, nil, 0); return Int(n) }()

    public init() { _ = sample() }

    /// Returns usage 0...1 for each logical core.
    public func sample() -> [Double] {
        var count: natural_t = 0, info: processor_info_array_t?, infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)) }
        let ticks = (0..<Int(count)).map { c in (0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[c * Int(CPU_STATE_MAX) + $0]) } }
        defer { last = ticks }
        guard last.count == ticks.count else { return Array(repeating: 0, count: ticks.count) }
        return zip(ticks, last).map { now, prev in
            let d = (0..<4).map { Double(now[$0] &- prev[$0]) }   // user, system, idle, nice
            let total = d.reduce(0, +)
            return total > 0 ? (total - d[Int(CPU_STATE_IDLE)]) / total : 0
        }
    }
}

// MARK: - GPU

/// GPU utilization (0...1) as reported by the IOAccelerator driver — the same number Activity Monitor uses.
public func gpuUsage() -> Double? {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == kIOReturnSuccess else { return nil }
    defer { IOObjectRelease(it) }
    var best: Double?
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        if let stats = IORegistryEntryCreateCFProperty(s, "PerformanceStatistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any],
           let u = stats["Device Utilization %"] as? Int {
            best = max(best ?? 0, Double(u) / 100)
        }
    }
    return best
}

// MARK: - Memory

public struct MemoryStats: Sendable {
    public let total, app, wired, compressed, cached, free: UInt64       // bytes
    public let swapTotal, swapUsed: UInt64
    public let pressure: Double                                          // 0...1 (100 - kern.memorystatus_level)
    public let swapIns, swapOuts: UInt64                                 // cumulative page counts
    public var used: UInt64 { app + wired + compressed }                 // what Activity Monitor calls "Memory Used"
}

public func memoryStats() -> MemoryStats? {
    var vm = vm_statistics64(), size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size) }
    }
    guard r == KERN_SUCCESS else { return nil }
    let page = UInt64(getpagesize())
    var total: UInt64 = 0, ts = 8; sysctlbyname("hw.memsize", &total, &ts, nil, 0)
    var swap = xsw_usage(), ss = MemoryLayout<xsw_usage>.size; sysctlbyname("vm.swapusage", &swap, &ss, nil, 0)
    var level: Int32 = 0, ls = 4; sysctlbyname("kern.memorystatus_level", &level, &ls, nil, 0)
    let purgeable = UInt64(vm.purgeable_count)
    return MemoryStats(
        total: total,
        app: (UInt64(vm.internal_page_count) - purgeable) * page,
        wired: UInt64(vm.wire_count) * page,
        compressed: UInt64(vm.compressor_page_count) * page,
        cached: (UInt64(vm.external_page_count) + purgeable) * page,
        free: (UInt64(vm.free_count) + UInt64(vm.speculative_count)) * page,
        swapTotal: swap.xsu_total, swapUsed: swap.xsu_used,
        pressure: Double(100 - level) / 100,
        swapIns: vm.swapins, swapOuts: vm.swapouts)
}

// MARK: - Disk

public struct VolumeUsage: Sendable, Identifiable {
    public let name: String
    public let total, available: UInt64
    public var id: String { name }
    public var used: Double { total > 0 ? Double(total - min(available, total)) / Double(total) : 0 }
}

/// Capacity of the boot volume plus any mounted external volumes.
public func volumes() -> [VolumeUsage] {
    let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeIsLocalKey]
    let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
    return urls.compactMap { url in
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsLocal == true,
              let total = v.volumeTotalCapacity, total > 0 else { return nil }
        let avail = v.volumeAvailableCapacityForImportantUsage.map(UInt64.init) ?? 0
        return VolumeUsage(name: url.path == "/" ? "Macintosh HD" : (v.volumeName ?? url.lastPathComponent),
                           total: UInt64(total), available: avail)
    }
}

/// Cumulative bytes read/written per physical disk (from IOBlockStorageDriver statistics).
public func diskIOCounters() -> [String: (read: UInt64, write: UInt64)] {
    var it: io_iterator_t = 0, out: [String: (UInt64, UInt64)] = [:]
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == kIOReturnSuccess else { return [:] }
    defer { IOObjectRelease(it) }
    while case let s = IOIteratorNext(it), s != 0 {
        defer { IOObjectRelease(s) }
        guard let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, nil, 0)?.takeRetainedValue() as? [String: Any] else { continue }
        var child: io_registry_entry_t = 0, name = "disk?"
        if IORegistryEntryGetChildEntry(s, kIOServicePlane, &child) == kIOReturnSuccess {
            name = IORegistryEntryCreateCFProperty(child, "BSD Name" as CFString, nil, 0)?.takeRetainedValue() as? String ?? name
            IOObjectRelease(child)
        }
        out[name] = ((st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0, (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
    }
    return out
}

// MARK: - Network

/// Cumulative 64-bit byte counters per interface (lo0 excluded). `names` caches
/// interface index -> name across calls, saving a lookup per interface per sample.
public func networkCounters(names: inout [UInt16: String]) -> [String: (rx: UInt64, tx: UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0], len = 0
    guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return [:] }
    var buf = [UInt8](repeating: 0, count: len)
    guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
    var out: [String: (UInt64, UInt64)] = [:], off = 0
    buf.withUnsafeBytes { raw in
        while off + MemoryLayout<if_msghdr>.size <= len {
            let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
            if Int32(hdr.ifm_type) == RTM_IFINFO2 {
                let m = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                if names[m.ifm_index] == nil {
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(m.ifm_index), &name) != nil {
                        names[m.ifm_index] = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                }
                if let n = names[m.ifm_index], n != "lo0" { out[n] = (m.ifm_data.ifi_ibytes, m.ifm_data.ifi_obytes) }
            }
            off += Int(hdr.ifm_msglen)
        }
    }
    return out
}
