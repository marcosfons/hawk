import Foundation

/// Temperature sensors exposed through the private IOHIDEventSystem API
/// (what Macs Fan Control and powermetrics-style tools use on Apple Silicon).
public final class HIDSensors {
    typealias CreateFn   = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    typealias MatchFn    = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    typealias ServicesFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    typealias PropFn     = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    typealias EventFn    = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    typealias FloatFn    = @convention(c) (CFTypeRef, Int32) -> Double

    private static func sym<T>(_ name: String, _: T.Type) -> T {
        unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)!, to: T.self)   // RTLD_DEFAULT
    }
    private let event = sym("IOHIDServiceClientCopyEvent", EventFn.self)
    private let value = sym("IOHIDEventGetFloatValue", FloatFn.self)
    private let kTemp: Int64 = 15   // kIOHIDEventTypeTemperature
    private var services: [(name: String, ref: CFTypeRef)] = []
    private let client: CFTypeRef?

    public init() {
        client = HIDSensors.sym("IOHIDEventSystemClientCreate", CreateFn.self)(kCFAllocatorDefault)?.takeRetainedValue()
        guard let client else { return }
        _ = HIDSensors.sym("IOHIDEventSystemClientSetMatching", MatchFn.self)(
            client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let list = HIDSensors.sym("IOHIDEventSystemClientCopyServices", ServicesFn.self)(client)?
            .takeRetainedValue() as? [CFTypeRef] ?? []
        let prop = HIDSensors.sym("IOHIDServiceClientCopyProperty", PropFn.self)
        // Each sensor name is reported several times (once per PMU, a degree or so apart);
        // reading one of each costs a third as many round trips. Calibration entries are not readings.
        var seen = Set<String>()
        services = list.compactMap { ref in
            let name = prop(ref, "Product" as CFString)?.takeRetainedValue() as? String ?? "?"
            guard !name.hasPrefix("PMU tcal"), seen.insert(name).inserted else { return nil }
            return (name, ref)
        }
    }

    /// One reading per sensor name.
    public func read() -> [(name: String, celsius: Double)] {
        services.compactMap { s in
            guard let e = event(s.ref, kTemp, 0, 0)?.takeRetainedValue() else { return nil }
            let v = value(e, Int32(kTemp << 16))
            return (v > -20 && v < 150) ? (s.name, v) : nil
        }
    }

    /// Readings grouped into the parts of the machine a person cares about.
    public struct Summary: Sendable { public var soc: [Double] = [], ssd: [Double] = [], battery: [Double] = [], other: [String: Double] = [:]; public init() {} }

    public func summary() -> Summary {
        var s = Summary()
        for (n, v) in read() {
            if n.hasPrefix("PMU tdie") { s.soc.append(v) }
            else if n.hasPrefix("NAND") { s.ssd.append(v) }
            else if n.hasPrefix("gas gauge") { s.battery.append(v) }
            else { s.other[n] = v }
        }
        return s
    }
}
