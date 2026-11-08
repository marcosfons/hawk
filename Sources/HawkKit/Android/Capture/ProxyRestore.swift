import Foundation

/// The rule that comes before any proxying (plan F3): whatever proxy the phone had
/// is saved before Hawk sets its own, and put back on stop, and on the next
/// connection after an unplug or a crash. If someone changed the proxy since,
/// theirs is left alone.
public struct ProxyRestore: Sendable, Equatable, Codable {
    /// The phone's proxy before Hawk's; nil when it had none (":0", empty or null).
    public let original: String?
    /// What Hawk set.
    public let set: String
    public let since: Date

    public static let file = "proxy.json"
    public static let read = "settings get global http_proxy"

    public init(original: String?, set: String, since: Date = Date()) {
        self.original = original
        self.set = set
        self.since = since
    }

    /// ":0", "", "null" mean no proxy.
    public static func normalise(_ value: String?) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty, v != ":0", v != "null" else { return nil }
        return v
    }

    /// `host:port`, plain characters only; nil otherwise.
    public static func setCommand(_ proxy: String) -> String? {
        guard proxy.wholeMatch(of: /[A-Za-z0-9.\-]{1,253}:\d{1,5}/) != nil else { return nil }
        return "settings put global http_proxy \(proxy)"
    }

    /// The command that puts the original back, given what the phone has now; nil
    /// when the phone no longer has Hawk's proxy (someone changed it: leave it).
    public func restoreCommand(current: String?) -> String? {
        guard Self.normalise(current) == set else { return nil }
        if let original, let cmd = Self.setCommand(original) { return cmd }
        return "settings put global http_proxy :0"
    }

    /// Restores the phone if a record is left (stop, reconnect after unplug or crash),
    /// then forgets the record. Logged.
    public static func restoreIfNeeded(on session: any DeviceSession, deviceName: String, store: DeviceStore?) async {
        guard let store, let record = await store.load(ProxyRestore.self, file, for: session.id) else { return }
        guard let current = try? await session.shell(read, timeout: .seconds(10)) else { return }
        if let cmd = record.restoreCommand(current: current.stdout) {
            let ok = (try? await session.shell(cmd, timeout: .seconds(10)))?.status == 0
            try? await ActionLog.append(device: deviceName, action: .change("Proxy restored to \(record.original ?? "none")"),
                                        result: ok ? .done : .failed("settings refused it"), id: session.id, store: store)
            guard ok else { return }
        }
        await store.remove(file: file, for: session.id)
    }
}
