import Foundation

/// "I plugged it in and nothing shows" (requirements 1.5): what the Mac sees on USB,
/// matched against what adb sees, turned into causes. Pure rules.
public enum ConnectionDoctor {
    public struct Finding: Sendable, Equatable, Identifiable {
        public enum Severity: Int, Sendable, Comparable {
            case ok, info, warning, problem
            public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }
        public let severity: Severity
        public let title: String
        public let detail: String
        public var id: String { title + detail }
    }

    public static func diagnose(usb: [USBDevice], adb: [Device], installation: AdbInstallation?, serverRunning: Bool) -> [Finding] {
        var out: [Finding] = []
        if let installation, installation.chosen == nil {
            out.append(.init(severity: .problem, title: "adb is not installed",
                             detail: "Install Android platform-tools: Android Studio's SDK Manager, or brew install android-platform-tools."))
        }
        if let installation, installation.hasVersionConflict {
            out.append(.init(severity: .problem, title: "Two adb versions are installed",
                             detail: "They restart each other's server on every call. " + installation.warnings.joined(separator: " ")))
        }
        if !serverRunning, installation?.chosen != nil {
            out.append(.init(severity: .warning, title: "The adb server is not running", detail: "Start it from the strip at the top."))
        }
        let phones = usb.filter(\.looksAndroid)
        let adbUSB = adb.filter { $0.transports.contains { $0.kind == .usb } }
        if phones.isEmpty, adbUSB.isEmpty {
            out.append(.init(severity: .problem, title: "No phone on USB",
                             detail: "The Mac sees no Android device. The cable may be charge-only or the port bad: try another cable or port, and unlock the phone."))
        }
        for p in phones {
            // The USB serial number is adb's serial for a USB transport.
            let match = adb.first { d in
                guard let serial = p.serial else { return false }
                return d.id.rawValue == serial || d.transports.contains { t in t.kind == .usb && t.serial == serial }
            }
            let speed = p.speedLabel.map { " Link: \($0)." } ?? ""
            if !p.hasADB {
                if p.hasMTP {
                    out.append(.init(severity: .problem, title: "\(p.name): USB debugging is off",
                                     detail: "The phone is in file transfer or photo mode without debugging. Turn on Developer options (tap Build number seven times in About phone), then USB debugging." + speed))
                } else {
                    out.append(.init(severity: .problem, title: "\(p.name): no adb interface",
                                     detail: "Debugging is off, or the phone is only charging. Choose File transfer in the USB notification, and turn on USB debugging in Developer options." + speed))
                }
                continue
            }
            switch match?.state {
            case .device?:
                out.append(.init(severity: p.speed.map { $0 < 3 } == true ? .info : .ok, title: "\(p.name): connected",
                                 detail: "adb sees it." + speed + (p.speed.map { $0 < 3 } == true ? " A USB 3 cable and port would make pulls and mirroring faster." : "")))
            case .unauthorized?:
                out.append(.init(severity: .warning, title: "\(p.name): waiting for authorization",
                                 detail: "Accept the debugging prompt on the phone. If it never appears, use Revoke USB debugging authorizations in Developer options and plug in again."))
            case .offline?:
                out.append(.init(severity: .warning, title: "\(p.name): offline", detail: "Restart the adb server (Restart adb at the top), or replug the cable."))
            case let state?:
                out.append(.init(severity: .info, title: "\(p.name): \(state.word)", detail: "adb sees it, but not as a running Android." + speed))
            case nil:
                out.append(.init(severity: .warning, title: "\(p.name): adb does not see it",
                                 detail: serverRunning ? "The adb interface is there but the server has not picked it up: restart adb." : "Start the adb server."))
            }
        }
        return out.sorted { $0.severity > $1.severity }
    }
}

/// Pairing over Wi-Fi by QR code (requirements 1.6, Android 11+): Hawk shows the
/// QR, the phone advertises a pairing service with that name, Hawk pairs with it.
public struct WirelessPairing: Sendable, Equatable {
    public let name: String
    public let code: String

    public init(name: String = "hawk-" + String(Int.random(in: 1000...9999)), code: String = String(format: "%06d", Int.random(in: 0...999_999))) {
        self.name = name
        self.code = code
    }

    /// What the phone's "Pair device with QR code" scanner reads.
    public var qrPayload: String { "WIFI:T:ADB;S:\(name);P:\(code);;" }

    /// The pairing service this QR made the phone advertise, from `adb mdns services`.
    public func service(in services: [MdnsService]) -> MdnsService? {
        services.first { $0.type.hasPrefix("_adb-tls-pairing") && $0.name == name }
    }

    public func pairArguments(_ service: MdnsService) -> [String] { ["pair", service.address, code] }
}

/// Real adb throughput (requirements 1.7): a temporary file pushed and pulled back,
/// always deleted on both sides.
public enum Throughput {
    public static let remote = "/data/local/tmp/hawk-speed.bin"
    public static let size = 32 << 20

    public static func measure(on session: any DeviceSession) async throws -> (push: Double, pull: Double) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "hawk-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let local = dir.appending(path: "out.bin"), back = dir.appending(path: "in.bin")
        var bytes = Data(count: size)
        bytes.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, size) }
        try bytes.write(to: local)
        defer { Task { _ = try? await session.shell("rm -f \(remote)", timeout: .seconds(10)) } }
        let clock = ContinuousClock()
        let t0 = clock.now
        try await session.push(local, to: remote, timeout: .seconds(120))
        let t1 = clock.now
        try await session.pull(remote, to: back, timeout: .seconds(120))
        let t2 = clock.now
        _ = try? await session.shell("rm -f \(remote)", timeout: .seconds(10))
        func rate(_ d: Duration) -> Double { Double(size) / max(Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18, 0.001) }
        return (rate(t1 - t0), rate(t2 - t1))
    }
}
