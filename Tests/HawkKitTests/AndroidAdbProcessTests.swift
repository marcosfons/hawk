import Foundation
import HawkKit
import Testing

/// /bin/sh stands in for adb: `sh -c SCRIPT`. Each test has its own child registry, so
/// "nothing left running" is checked per test even when tests run in parallel.
@Suite struct AndroidAdbProcessTests {
    private func shell(_ children: ChildProcesses = ChildProcesses()) -> AdbProcess {
        var p = AdbProcess(executable: "/bin/sh", children: children)
        p.grace = .milliseconds(300)
        return p
    }

    private func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    @Test func separatesStdoutStderrAndStatus() async throws {
        let out = try await shell().run(["-c", "echo out; echo err >&2; exit 3"], timeout: .seconds(5))
        #expect(out.text == "out\n")
        #expect(out.stderr == "err\n")
        #expect(out.status == 3)
        #expect(!out.truncated)
    }

    @Test func classifiesFailureFromStderr() async throws {
        let out = try await shell().run(["-c", "echo 'adb: device offline' >&2; exit 1"], timeout: .seconds(5))
        #expect(out.error == .deviceOffline)
        let ok = try await shell().run(["-c", "true"], timeout: .seconds(5))
        #expect(ok.error == nil)
    }

    @Test func slowCommandFinishes() async throws {
        let out = try await shell().run(["-c", "sleep 0.3; echo done"], timeout: .seconds(5))
        #expect(out.text == "done\n")
        #expect(out.duration >= .milliseconds(300))
    }

    @Test func hangingCommandTimesOutAndIsKilled() async throws {
        let children = ChildProcesses()
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: AdbError.timeout) {
            _ = try await shell(children).run(["-c", "sleep 30"], timeout: .milliseconds(300))
        }
        #expect(clock.now - start < .seconds(3))
        try await waitUntil { children.count == 0 }
    }

    @Test func childIgnoringSigtermIsKilledAfterGrace() async throws {
        let children = ChildProcesses()
        await #expect(throws: AdbError.timeout) {
            _ = try await shell(children).run(["-c", "trap '' TERM; while :; do sleep 0.05; done"], timeout: .milliseconds(200))
        }
        try await waitUntil(.seconds(3)) { children.count == 0 }
    }

    @Test func floodingBothPipesDoesNotDeadlock() async throws {
        // 2 MB on each pipe, written alternately: reading one pipe at a time would block.
        let script = "awk 'BEGIN { s = sprintf(\"%1024s\", \"\"); for (i = 0; i < 2048; i++) { printf \"%s\", s; printf \"%s\", s > \"/dev/stderr\" } }'"
        let out = try await shell().run(["-c", script], timeout: .seconds(10))
        #expect(out.stdout.count == 2048 * 1024)
        #expect(out.status == 0)
        // stderr is kept capped.
        #expect(out.stderr.utf8.count <= AdbError.maxStderr * 4)
    }

    @Test func stdoutPastTheCapIsTruncated() async throws {
        var p = shell()
        p.maxOutput = 1000
        let out = try await p.run(["-c", "head -c 100000 /dev/zero"], timeout: .seconds(5))
        #expect(out.stdout.count == 1000)
        #expect(out.truncated)
        #expect(out.status == 0)
    }

    @Test func inputReachesTheChild() async throws {
        let big = Data(repeating: UInt8(ascii: "x"), count: 300_000)
        let out = try await shell().run(["-c", "wc -c"], timeout: .seconds(5), input: big)
        #expect(out.text.trimmingCharacters(in: .whitespacesAndNewlines) == "300000")
    }

    @Test func missingExecutableIsNotInstalled() async {
        await #expect(throws: AdbError.notInstalled) {
            _ = try await AdbProcess(executable: "/nonexistent/adb", children: ChildProcesses()).run(["version"], timeout: .seconds(1))
        }
    }

    @Test func cancellingTheCallerStopsTheChild() async throws {
        let children = ChildProcesses()
        let p = shell(children)
        let task = Task { try await p.run(["-c", "sleep 30"], timeout: .seconds(60)) }
        try await waitUntil { children.count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        try await waitUntil { children.count == 0 }
    }

    @Test func grandchildHoldingThePipeDoesNotHang() async throws {
        // Like `adb start-server`, which leaves a server running with the pipes inherited.
        let out = try await shell().run(["-c", "(sleep 3 &) ; echo started"], timeout: .seconds(2))
        #expect(out.text == "started\n")
    }

    @Test func streamDeliversOutputAndEnds() async throws {
        var received = ""
        for try await chunk in shell().stream(["-c", "for i in 1 2 3; do echo line$i; sleep 0.02; done"]) {
            received += String(decoding: chunk, as: UTF8.self)
        }
        #expect(received == "line1\nline2\nline3\n")
    }

    @Test func streamEndsWithTheClassifiedError() async throws {
        await #expect(throws: AdbError.deviceNotFound) {
            for try await _ in shell().stream(["-c", "echo x; echo 'adb: no devices/emulators found' >&2; exit 1"]) {}
        }
    }

    @Test func cancellingTheConsumerStopsTheStream() async throws {
        let children = ChildProcesses()
        let p = shell(children)
        let consumer = Task {
            var chunks = 0
            for try await _ in p.stream(["-c", "while :; do echo tick; sleep 0.01; done"]) { chunks += 1 }
            return chunks
        }
        try await waitUntil { children.count == 1 }
        consumer.cancel()
        _ = try? await consumer.value
        try await waitUntil { children.count == 0 }
    }

    @Test func droppingTheStreamStopsTheChild() async throws {
        let children = ChildProcesses()
        do {
            let stream = shell(children).stream(["-c", "while :; do echo tick; sleep 0.01; done"])
            var it = stream.makeAsyncIterator()
            _ = try await it.next()
        }
        try await waitUntil { children.count == 0 }
    }

    @Test func killAllStopsEveryChild() async throws {
        let children = ChildProcesses()
        let p = shell(children)
        let tasks = (0..<3).map { _ in Task { try? await p.run(["-c", "sleep 30"], timeout: .seconds(60)) } }
        try await waitUntil { children.count == 3 }
        children.killAll()
        for t in tasks { _ = await t.value }
        #expect(children.count == 0)
    }

    @Test func labelsNeverCarrySerialsOrScripts() {
        #expect(AdbProcess.label(["-s", "FAKE0001", "shell", "pm list packages"]) == "adb shell")
        #expect(AdbProcess.label(["version"]) == "adb version")
        #expect(AdbProcess.label(["-s"]) == "adb")
    }

    private func waitUntil(_ limit: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("condition not met within \(limit)")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
