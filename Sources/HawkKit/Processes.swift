import Darwin
import Foundation

/// Cumulative counters for one process, as the kernel keeps them. Codable so the root
/// helper can send them for processes an unprivileged app may not read.
public struct ProcessCounters: Codable, Sendable, Equatable {
    public var pid: Int32
    public var uid: UInt32
    public var cpuTime: UInt64      // ns, user + system
    public var energy: UInt64       // nJ (the kernel's estimate of energy used)
    public var wakeups: UInt64      // package idle + interrupt wake-ups
    public var footprint: UInt64    // bytes: what Activity Monitor calls "Memory"
    public var resident: UInt64     // bytes in RAM
    public var peak: UInt64         // lifetime maximum footprint
    public var diskRead: UInt64     // bytes
    public var diskWrite: UInt64    // bytes
    public var threads: Int32       // -1 when unknown
}

/// One process as the kernel lists it: readable for every process, privileged or not.
public struct ProcessEntry: Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: UInt32
    public let command: String      // p_comm: truncated to 16 characters
    public let start: Int           // start time in seconds; with pid, identifies the process
}

public func listProcesses() -> [ProcessEntry] {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
    var size = 0
    guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
    var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
    size = procs.count * MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
    return procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { p in
        ProcessEntry(pid: p.kp_proc.p_pid, ppid: p.kp_eproc.e_ppid, uid: p.kp_eproc.e_ucred.cr_uid,
                     command: withUnsafeBytes(of: p.kp_proc.p_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) },
                     start: p.kp_proc.p_un.__p_starttime.tv_sec)
    }
}

private let timebase: (numer: UInt64, denom: UInt64) = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return (UInt64(info.numer), UInt64(max(info.denom, 1)))
}()

/// Counters for one process, or nil when the kernel refuses (another user's process
/// without root).
public func readCounters(_ pid: Int32, uid: UInt32) -> ProcessCounters? {
    var info = rusage_info_v6()
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
    }
    guard r == 0 else { return nil }
    var task = proc_taskinfo()
    let t = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout<proc_taskinfo>.size))
    return ProcessCounters(
        pid: pid, uid: uid,
        cpuTime: (info.ri_user_time + info.ri_system_time) * timebase.numer / timebase.denom,
        energy: info.ri_energy_nj,
        wakeups: info.ri_pkg_idle_wkups + info.ri_interrupt_wkups,
        footprint: info.ri_phys_footprint, resident: info.ri_resident_size,
        peak: info.ri_lifetime_max_phys_footprint,
        diskRead: info.ri_diskio_bytesread, diskWrite: info.ri_diskio_byteswritten,
        threads: t > 0 ? task.pti_threadnum : -1)
}

/// Counters for every process this process may read, optionally skipping one user's
/// processes (the helper skips the requester's own: the app reads those itself).
public func readAllCounters(skippingUID: UInt32? = nil) -> [ProcessCounters] {
    listProcesses().compactMap { p in p.uid == skippingUID ? nil : readCounters(p.pid, uid: p.uid) }
}

/// A process ready to show: identity plus rates since the previous sample.
public struct ProcessStat: Sendable, Identifiable {
    public let pid: Int32
    public let ppid: Int32
    public let name: String
    public let path: String?
    public let user: String
    public let isMine: Bool
    /// False when neither this app nor the helper could read the counters.
    public let readable: Bool
    public let cpu: Double          // 1.0 = one full core, smoothed over ~2 samples
    public let cpuTime: Double      // seconds since the process started
    public let power: Double        // watts
    public let wakeups: Double      // per second
    public let threads: Int
    public let memory: UInt64
    public let resident: UInt64
    public let peak: UInt64
    public let growth: Int64        // footprint change over the last minute
    public let disk: Double         // bytes/s read + written
    public let start: Int           // start time; with pid, identifies the process
    public let energy: Double       // joules used since the process started
    public var id: Int32 { pid }

    public init(pid: Int32, ppid: Int32 = 1, name: String, path: String? = nil, user: String = "", isMine: Bool = true,
                readable: Bool = true, cpu: Double = 0, cpuTime: Double = 0, power: Double = 0, wakeups: Double = 0,
                threads: Int = 1, memory: UInt64 = 0, resident: UInt64 = 0, peak: UInt64 = 0, growth: Int64 = 0,
                disk: Double = 0, start: Int = 0, energy: Double = 0) {
        self.pid = pid; self.ppid = ppid; self.name = name; self.path = path; self.user = user; self.isMine = isMine
        self.readable = readable; self.cpu = cpu; self.cpuTime = cpuTime; self.power = power; self.wakeups = wakeups
        self.threads = threads; self.memory = memory; self.resident = resident; self.peak = peak; self.growth = growth
        self.disk = disk; self.start = start; self.energy = energy
    }
}

/// Turns successive counter readings into per-process rates. Keeps per-process state
/// across calls; own it from one thread or actor.
public final class ProcessSampler {
    private struct Previous { let date: Date; let start: Int; let counters: ProcessCounters; let cpu: Double }
    private struct Identity { let start: Int; let name: String; let path: String? }

    private var previous: [Int32: Previous] = [:]
    private var identities: [Int32: Identity] = [:]
    private var users: [UInt32: String] = [:]
    private var footprints: [Int32: [(Date, UInt64)]] = [:]
    private let me = getuid()

    /// Weight of the newest reading in the CPU average. Lower = steadier ordering.
    public static let smoothing = 0.5
    public static let growthWindow = 60.0

    public init() {}

    /// `privileged` holds counters the helper read for processes this app cannot.
    public func sample(privileged: [ProcessCounters] = []) -> [ProcessStat] {
        let now = Date()
        let byPID = Dictionary(privileged.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let entries = listProcesses()
        var seen = Set<Int32>()
        let stats = entries.map { e -> ProcessStat in
            seen.insert(e.pid)
            let identity = identity(e)
            let counters = readCounters(e.pid, uid: e.uid) ?? byPID[e.pid]
            guard let c = counters else {
                return ProcessStat(pid: e.pid, ppid: e.ppid, name: identity.name, path: identity.path, user: user(e.uid),
                                   isMine: e.uid == me, readable: false, cpu: 0, cpuTime: 0, power: 0, wakeups: 0,
                                   threads: 0, memory: 0, resident: 0, peak: 0, growth: 0, disk: 0, start: e.start, energy: 0)
            }
            var cpu = 0.0, power = 0.0, wakeups = 0.0, disk = 0.0
            let prev = previous[e.pid].flatMap { $0.start == e.start ? $0 : nil }
            if let prev {
                let dt = max(now.timeIntervalSince(prev.date), 0.001)
                let p = prev.counters
                let instant = Double(c.cpuTime &- p.cpuTime) / 1e9 / dt
                cpu = prev.cpu * (1 - Self.smoothing) + instant * Self.smoothing
                power = Double(c.energy &- p.energy) / 1e9 / dt
                wakeups = Double(c.wakeups &- p.wakeups) / dt
                disk = Double((c.diskRead &- p.diskRead) &+ (c.diskWrite &- p.diskWrite)) / dt
            }
            previous[e.pid] = Previous(date: now, start: e.start, counters: c, cpu: cpu)
            var history = footprints[e.pid, default: []].filter { now.timeIntervalSince($0.0) <= Self.growthWindow }
            history.append((now, c.footprint))
            footprints[e.pid] = history
            let growth = Int64(bitPattern: c.footprint &- history[0].1)
            return ProcessStat(pid: e.pid, ppid: e.ppid, name: identity.name, path: identity.path, user: user(e.uid),
                               isMine: e.uid == me, readable: true, cpu: cpu, cpuTime: Double(c.cpuTime) / 1e9,
                               power: max(power, 0), wakeups: wakeups, threads: Int(c.threads), memory: c.footprint,
                               resident: c.resident, peak: c.peak, growth: growth, disk: disk,
                               start: e.start, energy: Double(c.energy) / 1e9)
        }
        // Forget processes that exited.
        for pid in previous.keys where !seen.contains(pid) { previous[pid] = nil; footprints[pid] = nil; identities[pid] = nil }
        return stats
    }

    private func identity(_ e: ProcessEntry) -> Identity {
        if let i = identities[e.pid], i.start == e.start { return i }
        var buf = [CChar](repeating: 0, count: 4096)
        let path = proc_pidpath(e.pid, &buf, UInt32(buf.count)) > 0
            ? String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        // The executable's own name is complete; p_comm stops at 16 characters.
        let name = path.map { ($0 as NSString).lastPathComponent } ?? e.command
        let i = Identity(start: e.start, name: name.isEmpty ? e.command : name, path: path)
        identities[e.pid] = i
        return i
    }

    private func user(_ uid: UInt32) -> String {
        if let u = users[uid] { return u }
        let name = getpwuid(uid).flatMap { String(validatingCString: $0.pointee.pw_name) } ?? String(uid)
        users[uid] = name
        return name
    }
}
