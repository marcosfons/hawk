import Foundation

/// Every way an adb call fails, recognised from its exit status and standard error.
/// Callers decide from the case (wait, restart with backoff, mark a device gone),
/// never from the text.
public enum AdbError: Error, Sendable, Equatable {
    /// No adb was found.
    case notInstalled
    /// "daemon not running; starting now" and nothing worse: wait, then retry.
    case serverStarting
    /// No server answers on its port.
    case serverUnreachable
    /// Two adb versions fight over one server; numbers as adb printed them, when it did.
    case versionMismatch(server: String?, client: String?)
    /// Another process holds port 5037.
    case portInUse
    case deviceNotFound
    case deviceOffline
    case unauthorized
    /// The connection to the device dropped mid-call: retry once, then gone.
    case closed
    /// The runner gave up waiting.
    case timeout
    /// Anything else, shown to the user as it is (capped).
    case commandFailed(status: Int32, stderr: String)

    /// Longest stderr kept in `commandFailed`: device output is untrusted.
    public static let maxStderr = 2000

    /// nil when the call succeeded. A zero status is success whatever stderr says (adb
    /// prints "starting now" there on a normal start).
    public static func classify(status: Int32, stderr: String) -> AdbError? {
        guard status != 0 else { return nil }
        let text = String(stderr.prefix(8192))
        let lower = text.lowercased()
        func has(_ s: String) -> Bool { lower.contains(s) }

        if has("doesn't match this client") || has("does not match this client") || has("adb server is out of date") {
            return .versionMismatch(server: number(after: "server version (", in: lower),
                                    client: number(after: "this client (", in: lower))
        }
        if has("smartsocket") || has("address already in use") { return .portInUse }
        if has("cannot connect to daemon") || has("cannot connect to adb server")
            // "connection refused" alone is also how `adb connect` reports an unreachable phone.
            || (has("connection refused") && has("5037"))
            || has("failed to start daemon") || has("could not read ok from adb server") {
            return .serverUnreachable
        }
        if has("no devices/emulators found") || has("device not found") || (has("device '") && has("' not found")) {
            return .deviceNotFound
        }
        if has("device offline") { return .deviceOffline }
        if has("unauthorized") { return .unauthorized }
        if has("error: closed") || has("protocol fault") { return .closed }
        if has("daemon not running") && has("starting now") { return .serverStarting }
        return .commandFailed(status: status, stderr: String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxStderr)))
    }

    /// One line for the interface.
    public var summary: String {
        switch self {
        case .notInstalled: "adb is not installed"
        case .serverStarting: "adb server is starting"
        case .serverUnreachable: "adb server is not answering"
        case .versionMismatch(let server, let client):
            if let server, let client { "Two adb versions are fighting over the server (server \(server), client \(client))" }
            else { "Two adb versions are fighting over the server" }
        case .portInUse: "Another process holds adb's port 5037"
        case .deviceNotFound: "Device not found"
        case .deviceOffline: "Device offline"
        case .unauthorized: "Device unauthorized: accept the prompt on the phone"
        case .closed: "Connection to the device closed"
        case .timeout: "adb did not answer in time"
        case .commandFailed(let status, let stderr): stderr.isEmpty ? "Exit status \(status)" : stderr
        }
    }

    private static func number(after marker: String, in text: String) -> String? {
        guard let start = text.range(of: marker)?.upperBound else { return nil }
        let digits = text[start...].prefix { $0.isNumber || $0 == "." }
        return digits.isEmpty || digits.count > 16 ? nil : String(digits)
    }
}
