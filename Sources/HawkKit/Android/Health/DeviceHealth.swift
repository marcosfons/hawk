import Foundation

/// Battery low and storage nearly full on a connected device (requirements 14.4).
/// Read in the same shell call as the crash watch's 60 s listing, at most every
/// 5 minutes, so it adds no call on the phone: `dumpsys battery` and `df` cost a
/// few milliseconds. Each condition alerts once, then stays quiet until it clears
/// with a margin (charging, or space freed), so a level hovering at the line does
/// not alert on every read.
public enum DeviceHealth {
    public static let marker = "--- hawk health ---"
    /// Appended to another script with `;`. Battery first, then the data partition.
    public static let probe = "echo '\(marker)'; dumpsys battery 2>/dev/null; echo '\(marker)'; df -k /data 2>/dev/null"
    public static let interval: TimeInterval = 300

    public static let batteryLow = 15
    public static let batteryClear = 25
    public static let storageLow = 0.10
    public static let storageClear = 0.15

    public struct Reading: Sendable, Equatable {
        public var battery: BatteryInfo?
        public var storage: DeviceStorage.Volume?
        public init(battery: BatteryInfo? = nil, storage: DeviceStorage.Volume? = nil) {
            self.battery = battery; self.storage = storage
        }
    }

    /// Splits a script's output at the probe: what came before it, and the reading.
    /// No marker, no reading; the text is returned untouched.
    public static func split(_ output: String) -> (before: String, reading: Reading?) {
        let parts = output.prefix(512 * 1024).components(separatedBy: marker + "\n")
        guard parts.count >= 3 else { return (output, nil) }
        let battery = OverviewProbe.parseBattery(parts[1])
        let storage = DeviceStorage.parseDf(parts[2]).first { $0.mount == "/data" }
        return (parts[0], Reading(battery: battery.level == nil ? nil : battery, storage: storage))
    }

    public enum Issue: String, Sendable, CaseIterable {
        case batteryLow, storageFull
    }

    public struct Alert: Sendable, Equatable {
        public let issue: Issue
        public let title: String
        public let body: String
    }

    /// What each device has already alerted about. Pure; one per app run.
    public struct Tracker: Sendable {
        private var raised: [DeviceID: Set<Issue>] = [:]
        public init() {}

        public mutating func evaluate(_ r: Reading, device: DeviceID, name: String) -> [Alert] {
            var out: [Alert] = []
            var set = raised[device] ?? []
            if let b = r.battery, let level = b.level {
                let charging = b.source != nil || b.status == "Charging" || b.status == "Full"
                if set.contains(.batteryLow) {
                    if charging || level >= DeviceHealth.batteryClear { set.remove(.batteryLow) }
                } else if !charging, level <= DeviceHealth.batteryLow {
                    set.insert(.batteryLow)
                    out.append(Alert(issue: .batteryLow, title: "\(name) battery low",
                                     body: "\(level)%, on battery. Plug it in before it shuts down mid-test."))
                }
            }
            if let v = r.storage, v.total > 0 {
                let free = Double(v.free) / Double(v.total)
                if set.contains(.storageFull) {
                    if free >= DeviceHealth.storageClear { set.remove(.storageFull) }
                } else if free < DeviceHealth.storageLow {
                    set.insert(.storageFull)
                    out.append(Alert(issue: .storageFull, title: "\(name) storage nearly full",
                                     body: "\(Format.bytes(Double(v.free))) free of \(Format.bytes(Double(v.total))) (\(Format.percent(free))). "
                                         + "Installs and captures fail when it runs out; its Storage section shows what to clear."))
                }
            }
            raised[device] = set
            return out
        }

        /// A device that is gone starts over: plugged back in still low, it alerts again.
        public mutating func forget(_ device: DeviceID) { raised[device] = nil }
    }
}
