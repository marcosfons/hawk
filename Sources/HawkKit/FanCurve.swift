import Foundation

/// Where a fan curve starts and where it reaches full speed, in °C.
public struct Threshold: Codable, Sendable, Equatable {
    public var start: Double
    public var full: Double
    public init(_ start: Double, _ full: Double) { self.start = start; self.full = full }
}

/// The temperatures a curve reacts to. Any of them may be missing.
public struct CurveTemps: Sendable, Equatable {
    public var soc, ssd, battery: Double?
    public init(soc: Double?, ssd: Double?, battery: Double?) { self.soc = soc; self.ssd = ssd; self.battery = battery }
}

/// A fan curve over three heat sources. Each source has its own thresholds; the hottest
/// one, relative to its thresholds, decides the speed. Below every start threshold the
/// fans are left to macOS, which keeps them off when the Mac is cool: that is the
/// cheapest state for the battery, and the fans cannot spin slower than their minimum anyway.
public struct FanCurve: Codable, Sendable, Equatable {
    public var soc: Threshold
    public var ssd: Threshold
    public var battery: Threshold

    public init(soc: Threshold, ssd: Threshold, battery: Threshold) {
        self.soc = soc; self.ssd = ssd; self.battery = battery
    }

    public static let quiet = FanCurve(soc: .init(70, 95), ssd: .init(60, 75), battery: .init(40, 45))
    public static let balanced = FanCurve(soc: .init(60, 90), ssd: .init(55, 70), battery: .init(37, 43))
    public static let cool = FanCurve(soc: .init(50, 80), ssd: .init(50, 65), battery: .init(35, 40))

    /// How far below a start threshold every source must fall before the fans are handed
    /// back, so they do not flap on and off around the threshold.
    public static let hysteresis = 4.0

    private func pairs(_ t: CurveTemps) -> [(Double, Threshold)] {
        [(t.soc, soc), (t.ssd, ssd), (t.battery, battery)].compactMap { v, th in v.map { ($0, th) } }
    }

    /// °C above the nearest start threshold; negative when every source is below its start.
    /// nil when no sensor is available.
    public func margin(_ t: CurveTemps) -> Double? {
        pairs(t).map { $0.0 - $0.1.start }.max()
    }

    /// 0 at the start threshold, 1 at full, for the hottest source.
    public func level(_ t: CurveTemps) -> Double {
        pairs(t).map { v, th in
            th.full > th.start ? min(max((v - th.start) / (th.full - th.start), 0), 1) : (v >= th.start ? 1 : 0)
        }.max() ?? 0
    }

    public enum Source: String, Sendable { case soc = "SoC", ssd = "SSD", battery = "Battery" }

    /// The source nearest to (or furthest past) its own thresholds: the one driving the fans.
    public func driver(_ t: CurveTemps) -> Source? {
        let candidates: [(Source, Double?, Threshold)] = [(.soc, t.soc, soc), (.ssd, t.ssd, ssd), (.battery, t.battery, battery)]
        return candidates.compactMap { src, v, th in v.map { (src, ($0 - th.start) / max(th.full - th.start, 1)) } }
            .max { $0.1 < $1.1 }?.0
    }

    /// Speed the curve asks for at a given level, between the fans' own limits.
    public static func rpm(level: Double, min lo: Double, max hi: Double) -> Double {
        lo + min(max(level, 0), 1) * (hi - lo)
    }
}

/// Turns a curve into a smooth speed over time: hysteresis on the way off, and
/// ramps that rise fast (heat) but fall slowly (noise changes are what people notice).
public struct CurveController: Sendable {
    public private(set) var rpm: Double?
    public static let rampUp = 800.0      // rpm per second
    public static let rampDown = 250.0

    public init() {}

    /// Returns the speed to hold, or nil to leave the fans to macOS.
    public mutating func step(curve: FanCurve, temps: CurveTemps, min lo: Double, max hi: Double, dt: Double) -> Double? {
        guard let margin = curve.margin(temps), hi > lo else { rpm = nil; return nil }
        if rpm == nil, margin < 0 { return nil }
        if rpm != nil, margin < -FanCurve.hysteresis { rpm = nil; return nil }
        let target = FanCurve.rpm(level: curve.level(temps), min: lo, max: hi)
        let current = rpm ?? lo
        let next = target > current ? min(target, current + Self.rampUp * dt) : max(target, current - Self.rampDown * dt)
        rpm = next
        return next
    }

    public mutating func reset() { rpm = nil }
}

public enum FanMode: String, Codable, Sendable, CaseIterable {
    case auto, curve, fixed
}

public struct ControlSettings: Codable, Sendable, Equatable {
    public var mode: FanMode = .auto
    public var curve: FanCurve = .balanced
    public var fixedRPM: Double = 3000
    /// On battery, leave the fans to macOS whatever the mode: it keeps them off when it can.
    public var macOSOnBattery = true
    public init() {}
}

/// What the app's control loop decided this tick.
public struct ControlStatus: Sendable, Equatable {
    public enum Helper: Sendable, Equatable { case unused, notInstalled, unavailable(String), connected }
    public var helper: Helper = .unused
    public var targetRPM: Double?     // nil: macOS controls the fans
    public var level: Double?         // curve mode: 0 at start, 1 at full
    public var note: String?          // why macOS is in control, or what went wrong
    public init() {}
}

public enum ControlPolicy {
    /// The speed to request this tick (nil = macOS) and, when macOS keeps control, why.
    public static func decide(_ settings: ControlSettings, temps: CurveTemps, onAC: Bool,
                              min lo: Double, max hi: Double, dt: Double,
                              controller: inout CurveController) -> (rpm: Double?, note: String?) {
        if settings.mode == .auto { controller.reset(); return (nil, nil) }
        if !onAC && settings.macOSOnBattery {
            controller.reset()
            return (nil, "On battery - macOS is in control to save power")
        }
        switch settings.mode {
        case .auto: return (nil, nil)
        case .fixed: return (min(max(settings.fixedRPM, lo), hi), nil)
        case .curve:
            let r = controller.step(curve: settings.curve, temps: temps, min: lo, max: hi, dt: dt)
            return (r, r == nil ? "Below the curve - macOS is in control" : nil)
        }
    }
}
