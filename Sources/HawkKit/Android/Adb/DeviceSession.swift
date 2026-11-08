import Foundation

/// What a shell command on the device printed.
public struct ShellResult: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var status: Int32
    public var duration: Duration

    public init(stdout: String, stderr: String = "", status: Int32 = 0, duration: Duration = .zero) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.duration = duration
    }
}

/// Everything a plan does with a device goes through this, never `adb` directly, so
/// timeouts, concurrency limits, errors and reconnection behave the same everywhere.
/// Calls fail fast with `AdbError.deviceNotFound` while the device is not usable.
public protocol DeviceSession: Sendable {
    var id: DeviceID { get }
    /// One shell command. A non-zero exit is a result, not an error.
    func shell(_ script: String, timeout: Duration) async throws -> ShellResult
    /// Several labelled commands in one call (every periodic read is done this way).
    /// Labels must pass `ShellBatch.isLabel`; a part cut short is missing from the result.
    func shellBatch(_ parts: [String: String], timeout: Duration) async throws -> [String: String]
    /// A long-lived command (`logcat`, `screenrecord`): stdout as it arrives.
    func stream(_ args: [String]) -> AsyncThrowingStream<Data, Error>
    func push(_ local: URL, to remote: String, timeout: Duration) async throws
    func pull(_ remote: String, to local: URL, timeout: Duration) async throws
    /// Any other adb command for this device (`install`, `forward`...): `-s` is added.
    func exec(_ args: [String], timeout: Duration) async throws -> AdbOutput
}

/// How many adb processes may run at once: 3 per device and 8 in all. Waiters are
/// served in order; a cancelled waiter leaves the queue.
public actor AdbSlots {
    public let perDevice: Int
    public let total: Int
    /// Long-lived streams per device; they do not take call slots.
    public let streamsPerDevice: Int

    private var calls: [DeviceID: Int] = [:]
    private var running = 0
    private var streams: [DeviceID: Int] = [:]
    private struct Waiter {
        let id: DeviceID
        let ticket: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var nextTicket = 0

    public init(perDevice: Int = 3, total: Int = 8, streamsPerDevice: Int = 4) {
        self.perDevice = perDevice
        self.total = total
        self.streamsPerDevice = streamsPerDevice
    }

    public var inUse: Int { running }

    public func acquire(_ id: DeviceID) async throws {
        // Only this device's earlier waiters go first; another device at its own limit
        // does not hold this one up (a waiter blocked by the total would already fit).
        if fits(id), !waiters.contains(where: { $0.id == id }) { return take(id) }
        nextTicket += 1
        let ticket = nextTicket
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                enqueue(Waiter(id: id, ticket: ticket, continuation: c))
            }
        } onCancel: {
            Task { await self.cancel(ticket) }
        }
    }

    public func release(_ id: DeviceID) {
        calls[id, default: 1] -= 1
        if calls[id] == 0 { calls[id] = nil }
        running -= 1
        serve()
    }

    public func openStream(_ id: DeviceID) -> Bool {
        guard streams[id, default: 0] < streamsPerDevice else { return false }
        streams[id, default: 0] += 1
        return true
    }

    public func closeStream(_ id: DeviceID) {
        streams[id, default: 1] -= 1
        if streams[id] == 0 { streams[id] = nil }
    }

    private func enqueue(_ waiter: Waiter) {
        if Task.isCancelled { waiter.continuation.resume(throwing: CancellationError()) } else { waiters.append(waiter) }
    }

    private func fits(_ id: DeviceID) -> Bool { running < total && calls[id, default: 0] < perDevice }

    private func take(_ id: DeviceID) {
        calls[id, default: 0] += 1
        running += 1
    }

    /// Wakes, in order, every waiter that now fits; one device at its limit does not
    /// hold up the others.
    private func serve() {
        var i = 0
        while i < waiters.count, running < total {
            if fits(waiters[i].id) {
                let w = waiters.remove(at: i)
                take(w.id)
                w.continuation.resume()
            } else {
                i += 1
            }
        }
    }

    private func cancel(_ ticket: Int) {
        guard let i = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
        waiters.remove(at: i).continuation.resume(throwing: CancellationError())
    }
}

/// The real session: adb with `-s <preferred transport's serial>`, resolved at each
/// call so a USB-to-Wi-Fi switch is invisible to callers.
public struct AdbDeviceSession: DeviceSession {
    public let id: DeviceID
    private let adb: AdbProcess
    private let slots: AdbSlots
    /// The serial to use now, nil while the device cannot take calls.
    private let serial: @Sendable () async -> String?
    /// Told when a call times out: the server may be hung.
    private let timedOut: @Sendable () async -> Void

    public init(id: DeviceID, adb: AdbProcess, slots: AdbSlots, serial: @escaping @Sendable () async -> String?,
                timedOut: @escaping @Sendable () async -> Void = {}) {
        self.id = id
        self.adb = adb
        self.slots = slots
        self.serial = serial
        self.timedOut = timedOut
    }

    public func shell(_ script: String, timeout: Duration) async throws -> ShellResult {
        let out = try await exec(["shell", script], timeout: timeout)
        // A shell exit status is a result; adb's own failures (device gone) are errors.
        // Only adb's lines are read: the command's own stderr may say anything.
        let adbLines = out.stderr.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("adb: ") || $0.hasPrefix("error: ") || $0.hasPrefix("* daemon") }
            .joined(separator: "\n")
        if out.status != 0, let error = AdbError.classify(status: out.status, stderr: adbLines), Self.isTransportError(error) {
            throw error
        }
        return ShellResult(stdout: out.text, stderr: out.stderr, status: out.status, duration: out.duration)
    }

    public func shellBatch(_ parts: [String: String], timeout: Duration) async throws -> [String: String] {
        guard !parts.isEmpty else { return [:] }
        guard parts.keys.allSatisfy(ShellBatch.isLabel) else { throw AdbError.commandFailed(status: -1, stderr: "Invalid batch label") }
        let token = ShellBatch.newToken()
        let result = try await shell(ShellBatch.script(parts, token: token), timeout: timeout)
        return ShellBatch.parse(result.stdout, labels: Set(parts.keys), token: token)
    }

    public func stream(_ args: [String]) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let task = Task(priority: .utility) {
            guard await slots.openStream(id) else {
                continuation.finish(throwing: AdbError.tooManyStreams)
                return
            }
            defer { Task { await slots.closeStream(id) } }
            guard let serial = await serial() else {
                continuation.finish(throwing: AdbError.deviceNotFound)
                return
            }
            do {
                for try await chunk in adb.stream(["-s", serial] + args) {
                    if case .dropped = continuation.yield(chunk) { Log.app.warning("Device stream: consumer too slow, output dropped") }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func push(_ local: URL, to remote: String, timeout: Duration) async throws {
        guard ShellQuote.isRemotePath(remote) else { throw AdbError.commandFailed(status: -1, stderr: "Invalid device path") }
        let out = try await exec(["push", local.path, remote], timeout: timeout)
        if let error = out.error { throw error }
    }

    public func pull(_ remote: String, to local: URL, timeout: Duration) async throws {
        guard ShellQuote.isRemotePath(remote) else { throw AdbError.commandFailed(status: -1, stderr: "Invalid device path") }
        let out = try await exec(["pull", remote, local.path], timeout: timeout)
        if let error = out.error { throw error }
    }

    public func exec(_ args: [String], timeout: Duration) async throws -> AdbOutput {
        guard let serial = await serial(), ShellQuote.isSerial(serial) else { throw AdbError.deviceNotFound }
        try await slots.acquire(id)
        do {
            let out = try await adb.run(["-s", serial] + args, timeout: timeout)
            await slots.release(id)
            return out
        } catch AdbError.timeout {
            await slots.release(id)
            await timedOut()
            throw AdbError.timeout
        } catch {
            await slots.release(id)
            throw error
        }
    }

    /// Errors that are about reaching the device, not about the command that ran on it.
    static func isTransportError(_ error: AdbError) -> Bool {
        switch error {
        case .deviceNotFound, .deviceOffline, .unauthorized, .closed, .serverUnreachable, .serverStarting,
             .versionMismatch, .portInUse, .notInstalled, .timeout, .tooManyStreams: true
        case .commandFailed: false
        }
    }
}
