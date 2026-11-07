import Foundation
import IOKit

public struct PowerInfo: Sendable {
    // Battery
    public var percent = 0, cycles = 0
    public var isCharging = false, onAC = false, fullyCharged = false
    public var minutesRemaining: Int?                 // to empty on battery, to full when charging
    public var voltage = 0.0, amperage = 0.0          // V, A (negative = discharging)
    public var designCapacity = 0, maxCapacity = 0    // mAh; maxCapacity is the gauge's nominal full charge
    /// Maximum Capacity exactly as System Settings shows it, when known (see `macOSBatteryHealth`).
    public var macOSHealth: Int?
    /// Battery health 0...1: macOS's own figure, else nominal full charge over design capacity.
    public var health: Double {
        if let macOSHealth { return Double(macOSHealth) / 100 }
        return designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) : 0
    }
    // Charger
    public var adapterName: String?
    public var adapterWatts = 0                       // negotiated
    public var adapterVolts = 0.0, adapterAmps = 0.0
    public var notChargingReason = 0
    public var slowChargingReason = 0
    /// Cumulative time the charger has slowed down because the battery was hot.
    public var thermallyLimitedSeconds = 0
    // Live power flow (W), from the PMU's telemetry
    public var systemLoad = 0.0                       // whole machine
    public var adapterIn = 0.0                        // from the charger
    public var batteryPower: Double { voltage * amperage }   // + charging, − discharging
    public init() {}
}

/// Reads AppleSmartBattery from the IORegistry. No privileges needed.
public func powerInfo() -> PowerInfo? {
    let s = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard s != 0 else { return nil }
    defer { IOObjectRelease(s) }
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(s, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
          let d = props?.takeRetainedValue() as? [String: Any] else { return nil }

    func int(_ dict: [String: Any]?, _ k: String) -> Int { (dict?[k] as? NSNumber).map { Int(truncatingIfNeeded: $0.int64Value) } ?? 0 }
    let battery = d["BatteryData"] as? [String: Any]
    let adapter = d["AdapterDetails"] as? [String: Any]
    let charger = d["ChargerData"] as? [String: Any]
    let telemetry = d["PowerTelemetryData"] as? [String: Any]

    var p = PowerInfo()
    p.percent = int(d, "CurrentCapacity")
    p.cycles = int(d, "CycleCount")
    p.isCharging = d["IsCharging"] as? Bool ?? false
    p.onAC = d["ExternalConnected"] as? Bool ?? false
    p.fullyCharged = d["FullyCharged"] as? Bool ?? false
    let t = int(d, "TimeRemaining")
    p.minutesRemaining = (t > 0 && t < 65535) ? t : nil
    p.voltage = Double(int(d, "Voltage")) / 1000
    p.amperage = Double(Int16(truncatingIfNeeded: int(d, "InstantAmperage"))) / 1000
    p.designCapacity = int(battery, "DesignCapacity")
    // Not AppleRawMaxCapacity: that is a live estimate that moves with temperature and load.
    p.maxCapacity = int(battery, "NominalChargeCapacity")
    if p.onAC, let adapter {
        p.adapterName = (adapter["Name"] as? String)?.trimmingCharacters(in: .whitespaces) ?? adapter["Description"] as? String
        p.adapterWatts = int(adapter, "Watts")
        p.adapterVolts = Double(int(adapter, "AdapterVoltage")) / 1000
        p.adapterAmps = Double(int(adapter, "Current")) / 1000
    }
    p.notChargingReason = int(charger, "NotChargingReason")
    p.slowChargingReason = int(charger, "SlowChargingReason")
    p.thermallyLimitedSeconds = int(charger, "TimeChargingThermallyLimited")
    p.systemLoad = Double(int(telemetry, "SystemLoad")) / 1000
    p.adapterIn = p.onAC ? Double(int(telemetry, "SystemPowerIn")) / 1000 : 0
    return p
}

/// "Maximum Capacity" as System Settings and System Information show it. macOS computes
/// it outside the battery's registry data (it is close to, but not exactly, nominal over
/// design capacity), so ask system_profiler. Takes about 0.1 s; call it rarely.
public func macOSBatteryHealth() -> Int? {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/sbin/system_profiler")
    process.arguments = ["SPPowerDataType", "-json"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch {
        Log.engine.warning("system_profiler did not start: \(error.localizedDescription)")
        return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard let json = try? JSONSerialization.jsonObject(with: data) else { return nil }

    func find(_ o: Any) -> String? {
        if let d = o as? [String: Any] {
            if let v = d["sppower_battery_health_maximum_capacity"] as? String { return v }
            return d.values.lazy.compactMap(find).first
        }
        if let a = o as? [Any] { return a.lazy.compactMap(find).first }
        return nil
    }
    return find(json).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "% "))) }
}
