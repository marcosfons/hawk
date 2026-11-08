import Foundation

/// Tunnels the user asked Hawk to keep: saved in the device folder and recreated
/// when the device comes back after a disconnect (adb drops them).
public enum SavedTunnels {
    public static let file = "tunnels.json"

    public static func load(_ id: DeviceID, store: DeviceStore?) async -> [Tunnel] {
        await store?.load([Tunnel].self, file, for: id) ?? []
    }

    public static func save(_ tunnels: [Tunnel], _ id: DeviceID, store: DeviceStore?) async {
        await store?.save(tunnels, as: file, for: id)
        await store?.flush()
    }

    /// Recreates every saved tunnel; returns how many worked.
    @discardableResult
    public static func restore(on session: any DeviceSession, store: DeviceStore?) async -> Int {
        var done = 0
        for t in await load(session.id, store: store) {
            guard let args = t.addArguments, let out = try? await session.exec(args, timeout: .seconds(10)), out.status == 0 else { continue }
            done += 1
        }
        if done > 0 { Log.app.info("Recreated \(done) adb tunnels") }
        return done
    }
}
