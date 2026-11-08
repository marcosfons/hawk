import Foundation

/// Decides what Hawk does about the adb server, and when. Pure: events and the time
/// come in, one action goes out, and `retryAt` says when to call again with `.tick`.
/// Every automatic action passes through here, so nothing can hot-loop:
///
/// - Backoff 1, 2, 5, 10, 30 s with jitter; after 5 failures in a row, `failing`,
///   retried every 60 s only while the Android tab is open, never while it is closed.
/// - Stopped by the user: no automatic action at all until the user starts it again.
/// - Version mismatch: no automatic restarts (they would fight the other adb).
/// - Not answering (hung): probed with the same backoff, never killed automatically.
public struct ServerPolicy: Sendable {
    public enum State: Sendable, Equatable {
        case stopped(byUser: Bool)
        case starting
        case running(version: Int)
        /// Accepts connections but does not answer in time; probed, not killed.
        case unhealthy(reason: String)
        /// Gone; started again at `until`.
        case backingOff(until: TimeInterval, attempt: Int, reason: String)
        /// Gave up retrying quickly.
        case failing(reason: String, since: TimeInterval)
        case versionMismatch(server: String?, client: String?)
    }

    public enum Event: Sendable, Equatable {
        /// Hawk started; `stoppedByUser` is the saved choice from the last run.
        case launch(stoppedByUser: Bool)
        /// The server answered `host:version` after a start or a probe.
        case answered(version: Int)
        case startFailed(AdbError)
        /// The connection closed or was refused: no server any more.
        case lost(reason: String)
        /// Connected, but `host:version` timed out or took over 3 s.
        case unresponsive(reason: String)
        /// A server someone else started, seen while stopped by the user.
        case foundRunning(version: Int)
        /// Time passed; acts when `retryAt` is reached.
        case tick
        case tabVisible(Bool)
        case userStart, userStop, userRestart
    }

    public enum Action: Sendable, Equatable {
        case none
        /// `adb start-server`, then wait for `host:version`.
        case start
        /// One `host:version` round trip.
        case probe
        /// Kill the server (user's Stop).
        case stop
        /// Kill and start (user's Restart).
        case restart
    }

    public static let backoff: [TimeInterval] = [1, 2, 5, 10, 30]
    public static let maxFailures = 5
    public static let slowRetry: TimeInterval = 60

    public private(set) var state: State = .stopped(byUser: false)
    /// When to send `.tick` next; nil when nothing is scheduled.
    public private(set) var retryAt: TimeInterval?
    /// Failures in a row since the server last answered.
    public private(set) var failures = 0
    /// The running server was started by another client while Hawk's was stopped.
    public private(set) var startedByOther = false
    public private(set) var tabOpen = false

    private var pending: Action = .none
    private let jitter: @Sendable () -> Double

    /// `jitter` returns a fraction added to each delay, within ±0.1 by default.
    public init(jitter: @escaping @Sendable () -> Double = { Double.random(in: -0.1...0.1) }) {
        self.jitter = jitter
    }

    public mutating func handle(_ event: Event, now: TimeInterval) -> Action {
        switch event {
        case .launch(let stoppedByUser):
            if stoppedByUser {
                _ = stop()
                return .none
            }
            state = .starting
            return .start

        case .answered(let version):
            guard !isUserStopped, !isMismatch else { return .none }
            state = .running(version: version)
            reset()
            return .none

        case .foundRunning(let version):
            guard isUserStopped else { return .none }
            state = .running(version: version)
            startedByOther = true
            reset()
            return .none

        case .startFailed(let error):
            guard !isUserStopped else { return .none }
            if case .versionMismatch(let server, let client) = error {
                state = .versionMismatch(server: server, client: client)
                reset()
                return .none
            }
            failures += 1
            schedule(.start, reason: error.summary, now: now)
            return .none

        case .lost(let reason):
            guard !isUserStopped, !isMismatch else { return .none }
            // A server that just went away is retried after the first delay; only failed
            // starts count toward giving up.
            if case .running = state { failures = 0 }
            schedule(.start, reason: reason, now: now)
            return .none

        case .unresponsive(let reason):
            guard !isUserStopped, !isMismatch else { return .none }
            failures += 1
            schedule(.probe, reason: reason, now: now)
            // The server is there; it stays "unhealthy" (not "failing") while it is probed.
            state = .unhealthy(reason: reason)
            return .none

        case .tick:
            guard let at = retryAt, now >= at else { return .none }
            retryAt = nil
            let action = pending
            pending = .none
            if action == .start { state = .starting }
            return action

        case .tabVisible(let open):
            tabOpen = open
            if failures >= Self.maxFailures, pending != .none {
                retryAt = open ? (retryAt ?? now + Self.slowRetry) : nil
            }
            return .none

        case .userStart:
            reset()
            startedByOther = false
            state = .starting
            return .start

        case .userStop:
            return stop()

        case .userRestart:
            reset()
            startedByOther = false
            state = .starting
            return .restart
        }
    }

    private var isUserStopped: Bool { state == .stopped(byUser: true) }

    private var isMismatch: Bool {
        if case .versionMismatch = state { return true }
        return false
    }

    private mutating func stop() -> Action {
        reset()
        startedByOther = false
        state = .stopped(byUser: true)
        return .stop
    }

    private mutating func reset() {
        failures = 0
        retryAt = nil
        pending = .none
    }

    private mutating func schedule(_ action: Action, reason: String, now: TimeInterval) {
        pending = action
        if failures >= Self.maxFailures {
            let since: TimeInterval
            if case .failing(_, let s) = state { since = s } else { since = now }
            state = .failing(reason: reason, since: since)
            retryAt = tabOpen ? now + Self.slowRetry : nil
            return
        }
        let base = Self.backoff[min(failures, Self.backoff.count - 1)]
        let delay = max(0.5, base * (1 + max(-0.5, min(0.5, jitter()))))
        retryAt = now + delay
        state = .backingOff(until: now + delay, attempt: failures, reason: reason)
    }
}
