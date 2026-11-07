import Foundation

/// Manual fan control on Apple Silicon, built around one rule: whatever happens, give control back.
///
/// Sequence (same idea as Macs Fan Control's `detectFtstForManualControl`):
///   1. `Ftst` = 1   — ask the SMC to release the fans from macOS's thermal manager
///   2. `FxMd` = 1   — fan x to manual (retried: macOS can take a few seconds to let go)
///   3. `FxTg` = rpm — target speed, always clamped to [FxMn, FxMx]
/// Restore: `FxMd` = 0 for every fan touched, then `Ftst` = 0.
public final class FanController {
    public enum ControlError: Error, CustomStringConvertible {
        case noFans, badFan(Int), modeRejected(Int)
        public var description: String {
            switch self {
            case .noFans: return "the SMC reports no fans"
            case .badFan(let i): return "fan \(i) does not exist"
            case .modeRejected(let i): return "fan \(i) would not switch to manual mode (macOS kept control)"
            }
        }
    }

    private let smc: SMC
    private var touched: [Int: Double] = [:]      // fan index -> target rpm
    private var unlocked = false

    public init(smc: SMC) { self.smc = smc }

    public var isEngaged: Bool { unlocked || !touched.isEmpty }

    /// Puts the given fans in manual mode at `rpm` (clamped). Returns the targets actually used.
    /// On any error it has already restored automatic control before throwing.
    @discardableResult
    public func set(rpm: Double, fans requested: [Int]? = nil) throws -> [Int: Double] {
        let all = smc.fans()
        guard !all.isEmpty else { throw ControlError.noFans }
        let indices = requested ?? all.map(\.index)
        for i in indices where !all.contains(where: { $0.index == i }) { throw ControlError.badFan(i) }

        do {
            if !touched.isEmpty, Set(indices) == Set(touched.keys) {
                for fan in all where touched[fan.index] != nil {
                    let target = min(max(rpm, fan.min), fan.max)
                    touched[fan.index] = target
                    try smc.write("F\(fan.index)Tg", target)
                }
                reassert()
                return touched
            }
            if smc.read("Ftst") != nil {
                unlocked = true                    // mark first, so restore() runs even if this write fails
                try smc.write("Ftst", 1)
            }
            for i in indices {
                let fan = all.first { $0.index == i }!
                let target = min(max(rpm, fan.min), fan.max)
                touched[i] = target
                try enterManual(i)
                try smc.write("F\(i)Tg", target)
            }
            return touched
        } catch {
            restore()
            throw error
        }
    }

    private func enterManual(_ i: Int) throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            do { try smc.write("F\(i)Md", 1) } catch SMC.WriteError.notPrivileged { throw SMC.WriteError.notPrivileged } catch {}
            if smc.number("F\(i)Md") == 1 { return }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw ControlError.modeRejected(i)
    }

    /// Call periodically while holding a speed: if macOS took a fan back, re-apply our setting.
    /// Returns the fans that had to be re-applied.
    @discardableResult
    public func reassert() -> [Int] {
        var fixed: [Int] = []
        for (i, target) in touched {
            let mode = smc.number("F\(i)Md"), tg = smc.number("F\(i)Tg")
            if mode != 1 || abs((tg ?? 0) - target) > 1 {
                try? smc.write("F\(i)Md", 1)
                try? smc.write("F\(i)Tg", target)
                fixed.append(i)
            }
        }
        return fixed
    }

    /// Gives every fan back to macOS. Safe to call any number of times.
    public func restore() {
        for i in touched.keys.sorted() { try? smc.write("F\(i)Md", 0) }
        if unlocked { try? smc.write("Ftst", 0) }
        touched = [:]; unlocked = false
    }

    /// Unconditional reset of every fan, for `fan auto` (e.g. after a crash or a kill -9).
    public static func resetAll(smc: SMC) throws {
        let fans = smc.fans()
        var firstError: Error?
        for f in fans { do { try smc.write("F\(f.index)Md", 0) } catch { firstError = firstError ?? error } }
        if smc.read("Ftst") != nil { do { try smc.write("Ftst", 0) } catch { firstError = firstError ?? error } }
        if let firstError { throw firstError }
    }
}
