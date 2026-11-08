import Foundation
import HawkKit
import Testing

private func line(_ i: Int, tag: String = "Fake", level: String = "I", uid: Int = 10100, pid: Int = 100) -> String {
    String(format: "11-08 10:00:%02d.%03d %d %d %d %@ %@: line %d\n", (i / 1000) % 60, i % 1000, uid, pid, pid, level, tag, i)
}

/// Applies updates the way the interface does.
private struct View {
    var lines: [LogEntry] = []
    var ended: String?
    mutating func apply(_ u: LogcatEngine.Update) {
        if u.reset { lines = u.lines } else { lines.removeFirst(min(u.dropped, lines.count)); lines += u.lines }
        if let e = u.ended { ended = e }
    }
}

private func collect(_ engine: LogcatEngine, until done: @escaping (View) -> Bool) async -> View {
    var view = View()
    for await u in engine.updates {
        view.apply(u)
        if done(view) { break }
    }
    return view
}

@Suite struct AndroidLogcatEngineTests {
    @Test func streamsParsesAndEnds() async {
        let fake = FakeDeviceSession()
        // Lines split across chunks, and a line without its newline yet.
        let text = (0..<10).map { line($0) }.joined()
        let cut = text.index(text.startIndex, offsetBy: 37)
        fake.answer(stream: LogcatEngine.command, with: [String(text[..<cut]), String(text[cut...])])
        let engine = LogcatEngine()
        await engine.start(fake)
        let view = await collect(engine) { $0.ended != nil }
        #expect(view.lines.map(\.message) == (0..<10).map { "line \($0)" })
        #expect(await !engine.running)
    }

    @Test func filterAppliesToNewAndOldLines() async {
        let fake = FakeDeviceSession()
        fake.answer(stream: LogcatEngine.command, with: [line(0, tag: "A"), line(1, tag: "B", level: "E"), line(2, tag: "A")])
        let engine = LogcatEngine()
        await engine.setFilter(LogFilter(parsing: "tag=:A"))
        await engine.start(fake)
        let view = await collect(engine) { $0.ended != nil }
        #expect(view.lines.map(\.message) == ["line 0", "line 2"])
        await engine.setFilter(LogFilter(parsing: "level:error"))
        #expect(await engine.visible().map(\.message) == ["line 1"])
    }

    @Test func ringIsCappedAndViewKeepsInStep() async {
        let fake = FakeDeviceSession()
        fake.answer(stream: LogcatEngine.command, with: (0..<30).map { line($0) })
        let engine = LogcatEngine(capacity: 10)
        await engine.start(fake)
        let view = await collect(engine) { $0.ended != nil }
        #expect(view.lines.map(\.message) == (20..<30).map { "line \($0)" })
        #expect(await engine.visible().count == 10)
    }

    @Test func processStartsFollowAnApp() async {
        let fake = FakeDeviceSession()
        fake.answer(stream: LogcatEngine.command, with: [
            "11-08 10:00:00.000 1000 50 60 I ActivityManager: Start proc 777:com.example.a/u0a100 for activity\n",
            "11-08 10:00:01.000 99999 777 777 I Mine: from the new process\n",
        ])
        let engine = LogcatEngine()
        await engine.setFilter(LogFilter(parsing: "package:com.example.a"))
        await engine.start(fake)
        let view = await collect(engine) { $0.ended != nil }
        #expect(view.lines.map(\.message) == ["from the new process"])
    }

    @Test func clearEmptiesTheView() async {
        let fake = FakeDeviceSession()
        fake.answer(stream: LogcatEngine.command, with: [line(0)])
        let engine = LogcatEngine()
        await engine.start(fake)
        _ = await collect(engine) { $0.ended != nil }
        await engine.clear()
        #expect(await engine.visible().isEmpty)
    }

    @Test func garbageInTheStreamIsSkipped() async {
        let fake = FakeDeviceSession()
        fake.answer(stream: LogcatEngine.command, with: ["--------- beginning of main\n", String(repeating: "\u{1}", count: 100) + "\n", line(1)])
        let engine = LogcatEngine()
        await engine.start(fake)
        let view = await collect(engine) { $0.ended != nil }
        #expect(view.lines.count == 1)
    }
}
