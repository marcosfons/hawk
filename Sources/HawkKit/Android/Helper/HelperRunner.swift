import CryptoKit
import Foundation

/// What to ask the helper in one run.
public enum HelperCommand: Sendable, Equatable {
    case apps
    case icons(px: Int, packages: [String])
    case net(from: Date, to: Date, step: TimeInterval)

    /// Arguments for app_process; nil when invalid (package names are checked).
    var arguments: [String]? {
        switch self {
        case .apps:
            return ["apps"]
        case .icons(let px, let packages):
            let valid = packages.filter { ShellQuote.isPackageName($0) || $0 == "android" }
            guard (8...128).contains(px), !valid.isEmpty else { return nil }
            return ["icons", String(px)] + valid
        case .net(let from, let to, let step):
            let f = Int64(from.timeIntervalSince1970 * 1000), t = Int64(to.timeIntervalSince1970 * 1000), s = Int64(step * 1000)
            guard s >= 3_600_000, t > f, (t - f) / s <= 400 else { return nil }
            return ["net", String(f), String(t), String(s)]
        }
    }
}

/// Runs Hawk's on-device helper (`android-helper/`): a small dex run by the shell
/// user with app_process, the way scrcpy runs its server. Pushed once per version to
/// /data/local/tmp (older versions removed), checked by SHA-256 on the phone before
/// every run, run at low priority under the phone's own `timeout` so nothing is left
/// running, and all pending work done in one run.
public struct HelperRunner: Sendable {
    public let dex: Data
    public let hash: String
    private let session: any DeviceSession

    public static let remoteFolder = "/data/local/tmp"
    static let missing = "HAWK-HELPER-MISSING"

    public init(dex: Data, session: any DeviceSession) {
        self.dex = dex
        self.hash = SHA256.hash(data: dex).map { String(format: "%02x", $0) }.joined()
        self.session = session
    }

    /// The dex bundled in Hawk.app (copied there by `make`).
    public static func bundledDex() -> Data? {
        Bundle.main.url(forResource: "hawk-helper", withExtension: "dex").flatMap { try? Data(contentsOf: $0) }
    }

    public var remotePath: String { "\(Self.remoteFolder)/hawk-helper-\(hash.prefix(16)).dex" }

    /// One run for all of `commands`. Pushes the helper first if the phone does not
    /// have this exact version.
    public func run(_ commands: [HelperCommand], timeout: Duration = .seconds(60)) async throws -> HelperOutput {
        let script = try self.script(commands, timeout: timeout)
        var result = try await session.shell(script, timeout: timeout + .seconds(5))
        if result.stdout.contains(Self.missing) {
            try await install()
            result = try await session.shell(script, timeout: timeout + .seconds(5))
            if result.stdout.contains(Self.missing) { throw AdbError.commandFailed(status: -1, stderr: "The helper could not be installed on the device") }
        }
        let text = result.stdout
        let output = await Task.detached(priority: .utility) { HelperOutput.parse(text) }.value
        if !output.complete {
            Log.app.warning("Android helper run did not complete (status \(result.status))")
        }
        for e in output.errors.prefix(3) { Log.app.warning("Android helper: \(e)") }
        if let cpu = output.stats["cpu_ms"] { Log.app.debug("Android helper run: \(cpu) ms CPU on the phone") }
        return output
    }

    /// The shell script for a run: verify the pushed file's hash, then run it.
    func script(_ commands: [HelperCommand], timeout: Duration) throws -> String {
        let args = commands.compactMap(\.arguments)
        guard !args.isEmpty else { throw AdbError.commandFailed(status: -1, stderr: "Nothing valid to ask the helper") }
        let joined = args.map { $0.map(ShellQuote.quote).joined(separator: " ") }.joined(separator: " -- ")
        let path = ShellQuote.quote(remotePath)
        let seconds = max(5, Int(timeout.components.seconds))
        return "[ \"$(sha256sum \(path) 2>/dev/null | cut -d' ' -f1)\" = \(hash) ] || { echo \(Self.missing); exit 0; }; "
            + "CLASSPATH=\(path) timeout \(seconds) nice -n 10 app_process / hawk.Helper \(joined)"
    }

    /// Removes older versions, then pushes this one.
    private func install() async throws {
        Log.app.info("Pushing the Android helper to the device")
        _ = try await session.shell("rm -f \(Self.remoteFolder)/hawk-helper-*.dex", timeout: .seconds(10))
        let local = FileManager.default.temporaryDirectory.appending(path: "hawk-helper-\(hash.prefix(16)).dex")
        try dex.write(to: local, options: .atomic)
        defer { try? FileManager.default.removeItem(at: local) }
        try await session.push(local, to: remotePath, timeout: .seconds(30))
    }
}
