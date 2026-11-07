import Foundation
import IOKit

/// Read-only access to the AppleSMC kernel driver.
/// Uses the driver's 80-byte SMCKeyData_t struct; offsets follow the C layout.
public final class SMC {
    private var conn: io_connect_t = 0
    private enum Cmd: UInt8 { case read = 5, write = 6, keyAtIndex = 8, keyInfo = 9 }
    private var infoCache: [UInt32: (size: UInt32, type: UInt32)] = [:]

    public init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }
    deinit { IOServiceClose(conn) }

    static func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
    static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
    }

    private func callRaw(_ input: [UInt8]) -> (kern_return_t, [UInt8]) {
        var out = [UInt8](repeating: 0, count: 80), outSize = 80
        let r = input.withUnsafeBytes { i in out.withUnsafeMutableBytes { o in
            IOConnectCallStructMethod(conn, 2, i.baseAddress, 80, o.baseAddress, &outSize) } }
        return (r, out)
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        let (r, out) = callRaw(input)
        guard r == kIOReturnSuccess, out[40] == 0 else { return nil }   // out[40] = SMC result
        return out
    }

    private func request(key: UInt32, cmd: Cmd) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: 80)
        withUnsafeBytes(of: key) { buf.replaceSubrange(0..<4, with: $0) }
        buf[42] = cmd.rawValue
        return buf
    }

    private func info(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let i = infoCache[key] { return i }
        guard let out = call(request(key: key, cmd: .keyInfo)) else { return nil }
        let i = (out[28..<32].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) },
                 out[32..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        infoCache[key] = i
        return i
    }

    public func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        let k = SMC.fourCC(key)
        guard let i = info(k), i.size <= 32 else { return nil }
        var buf = request(key: k, cmd: .read)
        withUnsafeBytes(of: i.size) { buf.replaceSubrange(28..<32, with: $0) }
        guard let out = call(buf) else { return nil }
        return (SMC.string(i.type), Array(out[48..<48 + Int(i.size)]))
    }

    public func number(_ key: String) -> Double? {
        guard let (t, b) = read(key) else { return nil }
        return SMC.decode(type: t, bytes: b)
    }

    public static func decode(type t: String, bytes b: [UInt8]) -> Double? {
        func be16() -> UInt16 { UInt16(b[0]) << 8 | UInt16(b[1]) }
        switch t {
        case "flt " where b.count == 4: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float.self) })
        case "ui8 ", "si8 ": return t == "ui8 " ? Double(b[0]) : Double(Int8(bitPattern: b[0]))
        case "ui16" where b.count == 2: return Double(be16())
        case "si16" where b.count == 2: return Double(Int16(bitPattern: be16()))
        case "ui32" where b.count == 4: return Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        case "fpe2" where b.count == 2: return Double(be16()) / 4
        case "sp78" where b.count == 2: return Double(Int16(bitPattern: be16())) / 256
        case "ioft" where b.count == 8: return Double(b.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) / 65536
        default: return nil
        }
    }

    /// Every key the SMC exposes (there are usually 1000–3000).
    public func allKeys() -> [String] {
        guard let n = number("#KEY") else { return [] }
        return (0..<UInt32(n)).compactMap { (idx: UInt32) -> String? in
            var buf = request(key: 0, cmd: .keyAtIndex)
            withUnsafeBytes(of: idx) { buf.replaceSubrange(44..<48, with: $0) }   // data32
            guard let out = call(buf) else { return nil }
            return SMC.string(out[0..<4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
    }

    // MARK: Writing (needs root)

    public enum WriteError: Error, CustomStringConvertible {
        case unknownKey(String), unsupportedType(String, String), notPrivileged, failed(String, kern_return_t, UInt8)
        public var description: String {
            switch self {
            case .unknownKey(let k): return "SMC key \(k) does not exist on this Mac"
            case .unsupportedType(let k, let t): return "SMC key \(k) has type '\(t)', which this tool will not write"
            case .notPrivileged: return "the SMC refused the write: root is required (use sudo)"
            case .failed(let k, let r, let smc): return String(format: "writing %@ failed (IOKit 0x%08x, SMC result %d)", k, r, smc)
            }
        }
    }

    /// Writes a number to a key, encoded the way that key's type requires.
    /// Only `ui8 ` and `flt ` keys are writable here — that is all fan control needs.
    public func write(_ key: String, _ value: Double) throws {
        let k = SMC.fourCC(key)
        guard let i = info(k) else { throw WriteError.unknownKey(key) }
        let type = SMC.string(i.type)
        let data: [UInt8]
        switch (type, i.size) {
        case ("ui8 ", 1): data = [UInt8(max(0, min(255, value)))]
        case ("flt ", 4): data = withUnsafeBytes(of: Float(value)) { Array($0) }
        default: throw WriteError.unsupportedType(key, type)
        }
        var buf = request(key: k, cmd: .write)
        withUnsafeBytes(of: i.size) { buf.replaceSubrange(28..<32, with: $0) }
        buf.replaceSubrange(48..<48 + data.count, with: data)
        let (r, out) = callRaw(buf)
        if r == Int32(bitPattern: 0xE00002C1) { throw WriteError.notPrivileged }   // kIOReturnNotPrivileged
        guard r == kIOReturnSuccess, out[40] == 0 else { throw WriteError.failed(key, r, out[40]) }
    }

    // MARK: Fans

    public struct Fan: Sendable, Equatable {
        public let index: Int
        public let actual, min, max, target: Double
        public let mode: Int
        public var isManual: Bool { mode == 1 }
    }

    /// Fan count and each fan's speed limits never change, so they are read once.
    private var fanLimits: [(min: Double, max: Double)]?

    public func fans() -> [Fan] {
        let limits = fanLimits ?? (0..<Int(number("FNum") ?? 0)).map { i in
            (number("F\(i)Mn") ?? 0, number("F\(i)Mx") ?? 0)
        }
        fanLimits = limits
        return limits.enumerated().map { i, l in
            let v: (String) -> Double = { self.number("F\(i)\($0)") ?? 0 }
            return Fan(index: i, actual: v("Ac"), min: l.min, max: l.max, target: v("Tg"), mode: Int(v("Md")))
        }
    }
}
