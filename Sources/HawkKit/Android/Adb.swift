import Foundation

/// One device as `adb devices -l` lists it.
public struct AndroidDevice: Sendable, Identifiable, Equatable {
    public let serial: String
    /// "device" when usable; "unauthorized", "offline", "recovery"… otherwise.
    public let state: String
    public let model: String?
    public let product: String?
    public let transportID: String?
    public var id: String { serial }
    public var isReady: Bool { state == "device" }
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }
    /// Wi-Fi debugging: "host:port" or an mDNS "adb-…._adb-tls-connect._tcp" name.
    public var isWireless: Bool { serial.contains(":") || serial.contains("._adb-tls-") }
    public var connection: String { isEmulator ? "Emulator" : isWireless ? "Wi-Fi" : "USB" }
}

/// What `getprop` and `dumpsys battery` say about one device.
public struct AndroidDetails: Sendable, Equatable {
    public var manufacturer: String?
    public var model: String?
    public var android: String?
    public var sdk: String?
    public var battery: Int?
    public var fetchedAt = Date()
}

public enum Adb {
    /// The platform-tools adb: the Android SDK's first, then Homebrew's.
    public static let executable: String? = ["~/Library/Android/sdk/platform-tools/adb", "/opt/homebrew/bin/adb", "/usr/local/bin/adb"]
        .map(StorageRules.expand)
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// nil when adb is not installed or did not answer.
    public static func devices() -> [AndroidDevice]? {
        guard let adb = executable, let r = runCommand(adb, ["devices", "-l"], timeout: 10), r.status == 0 else { return nil }
        return parseDevices(r.output)
    }

    public static func details(_ serial: String) -> AndroidDetails? {
        let script = "getprop ro.product.manufacturer; getprop ro.product.model; getprop ro.build.version.release; "
            + "getprop ro.build.version.sdk; dumpsys battery | grep -m1 level"
        guard let adb = executable, let r = runCommand(adb, ["-s", serial, "shell", script], timeout: 10), r.status == 0 else { return nil }
        return parseDetails(r.output)
    }

    /// "R5CX123   device usb:1-1 product:x model:SM_S928B device:e3q transport_id:3"
    public static func parseDevices(_ output: String) -> [AndroidDevice] {
        output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            var fields: [String: String] = [:]
            for p in parts.dropFirst(2) {
                if let colon = p.firstIndex(of: ":") { fields[String(p[..<colon])] = String(p[p.index(after: colon)...]) }
            }
            return AndroidDevice(serial: parts[0], state: parts[1], model: fields["model"]?.replacingOccurrences(of: "_", with: " "),
                                 product: fields["product"], transportID: fields["transport_id"])
        }
    }

    static func parseDetails(_ output: String) -> AndroidDetails {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func line(_ i: Int) -> String? { i < lines.count && !lines[i].isEmpty ? lines[i] : nil }
        let battery = lines.first { $0.hasPrefix("level:") }.flatMap { Int($0.dropFirst(6).trimmingCharacters(in: .whitespaces)) }
        return AndroidDetails(manufacturer: line(0), model: line(1), android: line(2), sdk: line(3), battery: battery)
    }
}
