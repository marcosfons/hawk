import Foundation
import Synchronization

/// What one finished adb call printed.
public struct AdbOutput: Sendable, Equatable {
    public var stdout: Data
    public var stderr: String
    public var status: Int32
    public var duration: Duration
    /// stdout went past the runner's cap; what was kept is the start.
    public var truncated: Bool

    public init(stdout: Data, stderr: String, status: Int32, duration: Duration, truncated: Bool = false) {
        self.stdout = stdout
        self.stderr = stderr
        self.status = status
        self.duration = duration
        self.truncated = truncated
    }

    public var text: String { String(decoding: stdout, as: UTF8.self) }
    /// nil when the call succeeded.
    public var error: AdbError? { AdbError.classify(status: status, stderr: stderr) }
}

/// Every child Hawk started and has not seen exit, so they can all be stopped on quit.
public final class ChildProcesses: Sendable {
    public static let shared = ChildProcesses()
    private let pids = Mutex<Set<pid_t>>([])

    public init() {}

    public var count: Int { pids.withLock { $0.count } }

    func insert(_ pid: pid_t) { pids.withLock { _ = $0.insert(pid) } }
    func remove(_ pid: pid_t) { pids.withLock { _ = $0.remove(pid) } }

    /// For children started elsewhere (scrcpy, ffmpeg), so they are stopped on quit too.
    public func track(_ pid: pid_t) { insert(pid) }
    public func untrack(_ pid: pid_t) { remove(pid) }

    /// SIGKILL to every child still running: called when Hawk quits, when there is no
    /// time for the SIGTERM grace period.
    public func killAll() {
        let all = pids.withLock { set in defer { set.removeAll() }; return set }
        for pid in all { kill(pid, SIGKILL) }
        if !all.isEmpty { Log.engine.info("Stopped \(all.count) child processes on quit") }
    }
}

/// Runs adb (or, in tests, any executable) without blocking a thread: stdout and stderr
/// are drained concurrently, every child has a timeout, and timeouts and cancellation
/// stop it with SIGTERM, then SIGKILL after a grace period.
public struct AdbProcess: Sendable {
    public let executable: String
    public let children: ChildProcesses
    /// stdout kept per call; the rest is drained and dropped (output is untrusted).
    public var maxOutput = 32 << 20
    /// Between SIGTERM and SIGKILL.
    public var grace: Duration = .seconds(2)
    /// Calls slower than this are logged as warnings.
    public var slowAbove: Duration = .seconds(3)

    public init(executable: String, children: ChildProcesses = .shared) {
        self.executable = executable
        self.children = children
    }

    /// Runs to completion. Throws `AdbError.timeout`, `CancellationError`, or a launch
    /// failure; a non-zero exit is a normal result (see `AdbOutput.error`).
    public func run(_ args: [String], timeout: Duration, input: Data? = nil) async throws -> AdbOutput {
        let started = ContinuousClock.now
        let child = try Child.launch(executable, args, input: input, maxOutput: maxOutput, children: children)
        let label = Self.label(args)
        let finished: Child.Result
        do {
            finished = try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Child.Result?.self) { group in
                    group.addTask { await child.result() }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        return nil
                    }
                    guard let first = try await group.next(), let result = first else {
                        // The group waits for the child's task before throwing: stop it first.
                        child.stop(grace: grace)
                        group.cancelAll()
                        throw AdbError.timeout
                    }
                    group.cancelAll()
                    return result
                }
            } onCancel: {
                child.stop(grace: grace)
            }
        } catch {
            child.stop(grace: grace)
            let ms = (ContinuousClock.now - started).milliseconds
            if error is AdbError {
                Log.engine.warning(String(format: "%@ timed out after %.0f ms", label, ms))
            } else {
                Log.engine.debug(String(format: "%@ cancelled after %.0f ms", label, ms))
            }
            throw error
        }
        try Task.checkCancellation()
        let duration = ContinuousClock.now - started
        let line = String(format: "%@: exit %d in %.0f ms", label, finished.status, duration.milliseconds)
        if duration > slowAbove { Log.engine.warning("Slow: " + line) } else { Log.engine.debug(line) }
        return AdbOutput(stdout: finished.stdout, stderr: String(decoding: finished.stderr, as: UTF8.self),
                         status: finished.status, duration: duration, truncated: finished.truncated)
    }

    /// A long-lived command (logcat, screenrecord): stdout as it arrives. Ends when the
    /// child exits, throwing the classified error if it failed; cancelling the consumer
    /// stops the child. At most `buffer` chunks wait for a slow consumer; beyond that the
    /// newest are dropped and the loss is logged.
    public func stream(_ args: [String], buffer: Int = 256) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(buffer))
        let label = Self.label(args)
        let child: Child
        do {
            child = try Child.launch(executable, args, input: nil, maxOutput: 0, children: children) { chunk in
                if case .dropped = continuation.yield(chunk) { Log.engine.warning("\(label): consumer too slow, output dropped") }
            }
        } catch {
            continuation.finish(throwing: error)
            return stream
        }
        let grace = grace
        let task = Task {
            let result = await child.result()
            let stderr = String(decoding: result.stderr, as: UTF8.self)
            Log.engine.debug("\(label): stream ended, exit \(result.status)")
            if let error = AdbError.classify(status: result.status, stderr: stderr), !result.stopped {
                continuation.finish(throwing: error)
            } else {
                continuation.finish()
            }
        }
        continuation.onTermination = { _ in
            child.stop(grace: grace)
            task.cancel()
        }
        return stream
    }

    /// "adb shell" for `-s SERIAL shell ...`: never serials, scripts or paths, which
    /// may reach hawk.log through a warning.
    public static func label(_ args: [String]) -> String {
        var i = 0
        while i < args.count, args[i].hasPrefix("-") {
            i += ["-s", "-t", "-H", "-P", "-L"].contains(args[i]) ? 2 : 1
        }
        return i < args.count ? "adb \(args[i])" : "adb"
    }
}

private extension Duration {
    var milliseconds: Double {
        let (s, atto) = components
        return Double(s) * 1000 + Double(atto) / 1e15
    }
}

/// One running child: its pipes drained on their own queue, its exit awaited without
/// blocking a thread.
private final class Child: Sendable {
    struct Result: Sendable {
        var stdout = Data()
        var stderr = Data()
        var status: Int32 = 0
        var truncated = false
        /// Hawk stopped it (timeout, cancel): its status is not a failure to report.
        var stopped = false
    }

    private struct State {
        var result = Result()
        var stdoutOpen = true
        var stderrOpen = true
        var exited = false
        var waiters: [CheckedContinuation<Result, Never>] = []
        var done: Result?
    }

    private let process: Process
    private let state = Mutex(State())
    private let maxOutput: Int
    private let onStdout: (@Sendable (Data) -> Void)?
    private let children: ChildProcesses
    private let pid: pid_t

    /// Pipes stay open after exit while a grandchild holds them (adb start-server forks
    /// the server); this long after exit, the output is taken as complete.
    private static let drainAfterExit: Duration = .milliseconds(500)

    private init(process: Process, maxOutput: Int, onStdout: (@Sendable (Data) -> Void)?, children: ChildProcesses) {
        self.process = process
        self.maxOutput = maxOutput
        self.onStdout = onStdout
        self.children = children
        self.pid = process.processIdentifier
    }

    static func launch(_ executable: String, _ args: [String], input: Data?, maxOutput: Int, children: ChildProcesses,
                       onStdout: (@Sendable (Data) -> Void)? = nil) throws -> Child {
        guard FileManager.default.isExecutableFile(atPath: executable) else { throw AdbError.notInstalled }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = args
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let inPipe: Pipe? = input == nil ? nil : Pipe()
        process.standardInput = inPipe ?? FileHandle.nullDevice
        let box = Mutex<Child?>(nil)
        process.terminationHandler = { p in box.withLock { $0 }?.exited(p.terminationStatus) }
        do { try process.run() } catch {
            throw AdbError.commandFailed(status: -1, stderr: "Could not start \((executable as NSString).lastPathComponent): \(error.localizedDescription)")
        }
        let child = Child(process: process, maxOutput: maxOutput, onStdout: onStdout, children: children)
        children.insert(child.pid)
        box.withLock { $0 = child }
        if !process.isRunning { child.exited(process.terminationStatus) }
        out.fileHandleForReading.readabilityHandler = { h in child.read(h.availableData, stdout: true, handle: h) }
        err.fileHandleForReading.readabilityHandler = { h in child.read(h.availableData, stdout: false, handle: h) }
        if let input, let inPipe {
            // Written off the caller's thread: a full pipe blocks until the child reads.
            DispatchQueue.global(qos: .utility).async {
                try? inPipe.fileHandleForWriting.write(contentsOf: input)
                try? inPipe.fileHandleForWriting.close()
            }
        }
        return child
    }

    func result() async -> Result {
        await withCheckedContinuation { c in
            let ready: Result? = state.withLock { s in
                if let done = s.done { return done }
                s.waiters.append(c)
                return nil
            }
            if let ready { c.resume(returning: ready) }
        }
    }

    /// SIGTERM now, SIGKILL after `grace` if it is still running.
    func stop(grace: Duration) {
        let alreadyDone = state.withLock { s in
            s.result.stopped = true
            return s.exited
        }
        guard !alreadyDone else { return }
        kill(pid, SIGTERM)
        let pid = pid
        Task.detached { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self, !self.state.withLock({ $0.exited }) else { return }
            kill(pid, SIGKILL)
        }
    }

    private func read(_ data: Data, stdout: Bool, handle: FileHandle) {
        if data.isEmpty {
            handle.readabilityHandler = nil
            finishIfDone { s in if stdout { s.stdoutOpen = false } else { s.stderrOpen = false } }
            return
        }
        if stdout, let onStdout {
            onStdout(data)
            return
        }
        state.withLock { s in
            if stdout {
                let room = maxOutput - s.result.stdout.count
                if room >= data.count { s.result.stdout.append(data) } else {
                    if room > 0 { s.result.stdout.append(data.prefix(room)) }
                    s.result.truncated = true
                }
            } else if s.result.stderr.count < AdbError.maxStderr * 4 {
                s.result.stderr.append(data.prefix(AdbError.maxStderr * 4 - s.result.stderr.count))
            }
        }
    }

    private func exited(_ status: Int32) {
        children.remove(pid)
        finishIfDone { s in
            s.exited = true
            s.result.status = status
        }
        Task.detached { [weak self] in
            try? await Task.sleep(for: Self.drainAfterExit)
            self?.finishIfDone { s in s.stdoutOpen = false; s.stderrOpen = false }
        }
    }

    private func finishIfDone(_ change: (inout State) -> Void) {
        let (waiters, result): ([CheckedContinuation<Result, Never>], Result?) = state.withLock { s in
            change(&s)
            guard s.done == nil, s.exited, !s.stdoutOpen, !s.stderrOpen else { return ([], nil) }
            s.done = s.result
            defer { s.waiters.removeAll() }
            return (s.waiters, s.result)
        }
        if let result { for w in waiters { w.resume(returning: result) } }
    }
}
