import HawkKit
import Testing

/// The clock is a number passed in; jitter is off unless a test sets it.
@Suite struct AndroidServerPolicyTests {
    private func policy(jitter: Double = 0) -> ServerPolicy { ServerPolicy(jitter: { jitter }) }

    /// Runs an adb that always fails to start, ticking exactly when asked, for `seconds`.
    /// Returns how many starts were attempted.
    private func failForever(_ p: inout ServerPolicy, from start: Double, seconds: Double) -> Int {
        var now = start
        var starts = 0
        while now < start + seconds {
            guard let at = p.retryAt else { break }
            now = max(now, at)
            if p.handle(.tick, now: now) == .start {
                starts += 1
                _ = p.handle(.startFailed(.serverUnreachable), now: now)
            }
        }
        return starts
    }

    @Test func launchStartsThenRuns() {
        var p = policy()
        #expect(p.handle(.launch(stoppedByUser: false), now: 0) == .start)
        #expect(p.state == .starting)
        #expect(p.handle(.answered(version: 41), now: 1) == .none)
        #expect(p.state == .running(version: 41))
        #expect(p.retryAt == nil)
    }

    @Test func backoffIsOneTwoFiveTenThirtyThenFailing() {
        var p = policy()
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.answered(version: 41), now: 0)
        _ = p.handle(.lost(reason: "closed"), now: 100)
        var delays: [Double] = []
        var now = 100.0
        while let at = p.retryAt {
            delays.append(at - now)
            now = at
            #expect(p.handle(.tick, now: now) == .start)
            _ = p.handle(.startFailed(.serverUnreachable), now: now)
        }
        #expect(delays == [1, 2, 5, 10, 30])
        #expect(p.state == .failing(reason: AdbError.serverUnreachable.summary, since: now))
    }

    @Test func ticksBeforeTheTimeDoNothing() {
        var p = policy()
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.startFailed(.serverUnreachable), now: 0)
        for t in stride(from: 0.0, to: 1.99, by: 0.1) { #expect(p.handle(.tick, now: t) == .none) }
        #expect(p.handle(.tick, now: 2) == .start)
        #expect(p.handle(.tick, now: 2.1) == .none)
    }

    @Test func failingWithTabClosedNeverRetries() {
        var p = policy()
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.startFailed(.serverUnreachable), now: 0)
        let starts = failForever(&p, from: 0, seconds: 24 * 3600)
        #expect(starts == 4)
        #expect(p.retryAt == nil)
        #expect(p.failures == ServerPolicy.maxFailures)
    }

    @Test func failingWithTabOpenRetriesEveryMinute() {
        var p = policy()
        _ = p.handle(.tabVisible(true), now: 0)
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.startFailed(.serverUnreachable), now: 0)
        _ = failForever(&p, from: 0, seconds: 47)   // reaches failing
        let hour = failForever(&p, from: 47, seconds: 3600)
        #expect(hour >= 59 && hour <= 61)
    }

    @Test func closingTheTabStopsSlowRetriesAndOpeningResumesThem() {
        var p = policy()
        _ = p.handle(.tabVisible(true), now: 0)
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.startFailed(.serverUnreachable), now: 0)
        _ = failForever(&p, from: 0, seconds: 47)
        #expect(p.retryAt != nil)
        _ = p.handle(.tabVisible(false), now: 50)
        #expect(p.retryAt == nil)
        _ = p.handle(.tabVisible(true), now: 500)
        #expect(p.retryAt == 560)
    }

    @Test func userStopMeansNothingAutomatic() {
        var p = policy()
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.answered(version: 41), now: 0)
        #expect(p.handle(.userStop, now: 10) == .stop)
        #expect(p.state == .stopped(byUser: true))
        // The kill closes the socket; that is not a reason to start again.
        #expect(p.handle(.lost(reason: "closed"), now: 11) == .none)
        #expect(p.handle(.startFailed(.serverUnreachable), now: 12) == .none)
        #expect(p.handle(.tabVisible(true), now: 13) == .none)
        for t in stride(from: 14.0, to: 10_000, by: 7) { #expect(p.handle(.tick, now: t) == .none) }
        #expect(p.retryAt == nil)
        #expect(p.state == .stopped(byUser: true))
    }

    @Test func savedStopIsKeptAtLaunch() {
        var p = policy()
        #expect(p.handle(.launch(stoppedByUser: true), now: 0) == .none)
        #expect(p.state == .stopped(byUser: true))
        #expect(p.handle(.userStart, now: 5) == .start)
        #expect(p.state == .starting)
    }

    @Test func serverStartedBySomeoneElseIsPickedUp() {
        var p = policy()
        _ = p.handle(.launch(stoppedByUser: true), now: 0)
        #expect(p.handle(.foundRunning(version: 41), now: 30) == .none)
        #expect(p.state == .running(version: 41))
        #expect(p.startedByOther)
        // Only while stopped: a running server found again changes nothing.
        var q = policy()
        _ = q.handle(.launch(stoppedByUser: false), now: 0)
        _ = q.handle(.answered(version: 41), now: 0)
        _ = q.handle(.foundRunning(version: 41), now: 1)
        #expect(!q.startedByOther)
    }

    @Test func versionMismatchNeverRestartsOnItsOwn() {
        var p = policy()
        _ = p.handle(.tabVisible(true), now: 0)
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        #expect(p.handle(.startFailed(.versionMismatch(server: "40", client: "41")), now: 1) == .none)
        #expect(p.state == .versionMismatch(server: "40", client: "41"))
        #expect(p.retryAt == nil)
        #expect(p.handle(.lost(reason: "closed"), now: 2) == .none)
        for t in stride(from: 3.0, to: 3600, by: 11) { #expect(p.handle(.tick, now: t) == .none) }
        #expect(p.handle(.userRestart, now: 4000) == .restart)
        #expect(p.state == .starting)
    }

    @Test func hungServerIsProbedNotKilled() {
        var p = policy()
        _ = p.handle(.tabVisible(true), now: 0)
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.answered(version: 41), now: 0)
        _ = p.handle(.unresponsive(reason: "no answer in 3 s"), now: 10)
        #expect(p.state == .unhealthy(reason: "no answer in 3 s"))
        var actions: [ServerPolicy.Action] = []
        var now = 10.0
        for _ in 0..<8 {
            guard let at = p.retryAt else { break }
            now = at
            let a = p.handle(.tick, now: now)
            actions.append(a)
            _ = p.handle(.unresponsive(reason: "no answer in 3 s"), now: now)
        }
        #expect(actions.allSatisfy { $0 == .probe })
        #expect(p.state == .unhealthy(reason: "no answer in 3 s"))
        // Resumed (kill -CONT): the next probe answers.
        _ = p.handle(.tick, now: p.retryAt ?? now)
        _ = p.handle(.answered(version: 41), now: now + 61)
        #expect(p.state == .running(version: 41))
        #expect(p.failures == 0)
    }

    @Test func lostAfterRunningRetriesAfterOneSecondAgain() {
        var p = policy()
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        _ = p.handle(.startFailed(.serverUnreachable), now: 0)
        _ = p.handle(.tick, now: 2)
        _ = p.handle(.answered(version: 41), now: 2)
        _ = p.handle(.lost(reason: "closed"), now: 100)
        #expect(p.retryAt == 101)
    }

    @Test func jitterStaysBounded() {
        var high = policy(jitter: 5)
        _ = high.handle(.launch(stoppedByUser: false), now: 0)
        _ = high.handle(.answered(version: 41), now: 0)
        _ = high.handle(.lost(reason: "x"), now: 0)
        #expect(high.retryAt == 1.5)
        var low = policy(jitter: -5)
        _ = low.handle(.launch(stoppedByUser: false), now: 0)
        _ = low.handle(.answered(version: 41), now: 0)
        _ = low.handle(.lost(reason: "x"), now: 0)
        #expect(low.retryAt == 0.5)
    }

    @Test func neverMoreThanOneActionPerDelay() {
        // Whatever the event mix, two automatic actions are never closer than the
        // shortest delay with the strongest negative jitter.
        var p = policy(jitter: -0.1)
        _ = p.handle(.tabVisible(true), now: 0)
        _ = p.handle(.launch(stoppedByUser: false), now: 0)
        var last = -Double.infinity
        var now = 0.0
        let events: [ServerPolicy.Event] = [.startFailed(.serverUnreachable), .lost(reason: "x"), .unresponsive(reason: "y"),
                                            .startFailed(.portInUse), .tick, .tick, .tabVisible(false), .tabVisible(true)]
        for i in 0..<5000 {
            now += 0.05
            let action = p.handle(events[i % events.count], now: now)
            if action == .start || action == .probe {
                #expect(now - last >= 0.9 - 1e-9)
                last = now
            }
        }
    }
}
