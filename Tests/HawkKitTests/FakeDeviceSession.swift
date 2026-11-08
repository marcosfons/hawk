import Foundation
import HawkKit
import Synchronization

/// A `DeviceSession` with scripted answers, for testing logic that talks to a device
/// without one. Every plan can use it:
///
///     let fake = FakeDeviceSession()
///     fake.answer(shell: "dumpsys battery", with: "level: 80\n")
///     fake.answer(batch: "battery", with: "level: 80\n")
///     fake.fail(with: .deviceOffline)            // every call from now on
///
/// Unscripted shell commands answer "" with status 0; calls are recorded in order.
final class FakeDeviceSession: DeviceSession {
    let id: DeviceID

    private struct State {
        var shell: [String: ShellResult] = [:]
        /// Answers used once each, in order, before `shell`'s.
        var queued: [String: [ShellResult]] = [:]
        var batch: [String: String] = [:]
        var exec: [String: AdbOutput] = [:]
        var streams: [String: [Data]] = [:]
        var error: AdbError?
        var calls: [String] = []
    }
    private let state = Mutex(State())

    init(id: DeviceID = DeviceID("FAKE0001")) {
        self.id = id
    }

    var calls: [String] { state.withLock { $0.calls } }

    func answer(shell script: String, with stdout: String, status: Int32 = 0) {
        state.withLock { $0.shell[script] = ShellResult(stdout: stdout, status: status) }
    }

    /// Answers for successive calls of the same script, used once each.
    func queue(shell script: String, outputs: [String]) {
        state.withLock { $0.queued[script, default: []] += outputs.map { ShellResult(stdout: $0) } }
    }

    /// The output of the batch part with this label, whatever its command.
    func answer(batch label: String, with output: String) {
        state.withLock { $0.batch[label] = output }
    }

    func answer(exec args: [String], with output: AdbOutput) {
        state.withLock { $0.exec[args.joined(separator: " ")] = output }
    }

    func answer(stream args: [String], with chunks: [String]) {
        state.withLock { $0.streams[args.joined(separator: " ")] = chunks.map { Data($0.utf8) } }
    }

    /// Every call fails with this until set back to nil.
    func fail(with error: AdbError?) {
        state.withLock { $0.error = error }
    }

    private func record(_ call: String) throws {
        let error = state.withLock { s in
            s.calls.append(call)
            return s.error
        }
        if let error { throw error }
    }

    func shell(_ script: String, timeout: Duration) async throws -> ShellResult {
        try record("shell \(script)")
        return state.withLock { s in
            if var q = s.queued[script], !q.isEmpty {
                let first = q.removeFirst()
                s.queued[script] = q
                return first
            }
            return s.shell[script]
        } ?? ShellResult(stdout: "")
    }

    func shellBatch(_ parts: [String: String], timeout: Duration) async throws -> [String: String] {
        try record("batch \(parts.keys.sorted().joined(separator: ","))")
        let answers = state.withLock { $0.batch }
        return parts.keys.reduce(into: [:]) { out, label in out[label] = answers[label] ?? "" }
    }

    func stream(_ args: [String]) -> AsyncThrowingStream<Data, Error> {
        let key = args.joined(separator: " ")
        let (chunks, error) = state.withLock { s in
            s.calls.append("stream \(key)")
            return (s.streams[key] ?? [], s.error)
        }
        return AsyncThrowingStream { c in
            for chunk in chunks { c.yield(chunk) }
            c.finish(throwing: error)
        }
    }

    func push(_ local: URL, to remote: String, timeout: Duration) async throws {
        try record("push \(local.lastPathComponent) \(remote)")
    }

    func pull(_ remote: String, to local: URL, timeout: Duration) async throws {
        try record("pull \(remote) \(local.lastPathComponent)")
    }

    func exec(_ args: [String], timeout: Duration) async throws -> AdbOutput {
        let key = args.joined(separator: " ")
        try record("exec \(key)")
        return state.withLock { $0.exec[key] } ?? AdbOutput(stdout: Data(), stderr: "", status: 0, duration: .zero)
    }
}
