import Foundation

/// Network traffic per process, from `nettop` (no root needed; ~20 ms per call).
/// nettop reports cumulative bytes per process; rates come from successive calls.
public struct NetworkProcess: Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    public let rxRate: Double       // bytes/s
    public let txRate: Double
    public let rxTotal: UInt64      // since the process started
    public let txTotal: UInt64
    public var id: Int32 { pid }
}

public final class NetworkSampler {
    private var last: [Int32: (date: Date, rx: UInt64, tx: UInt64)] = [:]

    public init() {}

    public func sample(now: Date = Date()) -> [NetworkProcess] {
        guard let r = runCommand("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"], timeout: 5), r.status == 0 else {
            Log.engine.warning("nettop failed")
            return []
        }
        var seen: [Int32: (Date, UInt64, UInt64)] = [:]
        let rows = Self.parse(r.output).map { row -> NetworkProcess in
            seen[row.pid] = (now, row.rx, row.tx)
            var rxRate = 0.0, txRate = 0.0
            if let p = last[row.pid], row.rx >= p.rx, row.tx >= p.tx {
                let dt = max(now.timeIntervalSince(p.date), 0.001)
                rxRate = Double(row.rx - p.rx) / dt
                txRate = Double(row.tx - p.tx) / dt
            }
            return NetworkProcess(pid: row.pid, name: row.name, rxRate: rxRate, txRate: txRate, rxTotal: row.rx, txTotal: row.tx)
        }
        last = seen.mapValues { (date: $0.0, rx: $0.1, tx: $0.2) }
        return rows
    }

    /// Lines look like "Google Chrome H.1234,5484,11848," (name truncated, then .pid).
    public static func parse(_ output: String) -> [(pid: Int32, name: String, rx: UInt64, tx: UInt64)] {
        output.split(separator: "\n").compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."), let pid = Int32(f[0][f[0].index(after: dot)...]),
                  let rx = UInt64(f[1]), let tx = UInt64(f[2]) else { return nil }
            return (pid, String(f[0][..<dot]), rx, tx)
        }
    }
}
