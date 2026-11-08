import Foundation
import HawkKit
import Testing

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}

private func parser() -> LogParser { LogParser(now: Date(timeIntervalSince1970: 1_800_000_000), calendar: utc) }

@Suite struct AndroidLogcatParserTests {
    private func parse(_ lines: [String]) -> [LogEntry?] {
        var p = parser()
        return lines.map { p.parse(Substring($0)) }
    }

    @Test func parsesAThreadtimeUidLine() throws {
        let e = try #require(parse(["11-08 00:02:44.264  1000 19501 19505 I FakeService: hello: world"])[0])
        #expect(e.level == .info && e.uid == 1000 && e.pid == 19501 && e.tid == 19505)
        #expect(e.tag == "FakeService" && e.message == "hello: world")
        let expected = utc.date(from: DateComponents(year: 2027, month: 11, day: 8, hour: 0, minute: 2, second: 44))!.timeIntervalSince1970 + 0.264
        #expect(abs(e.time - expected) < 0.001)
    }

    @Test func everyLevelAndNamedUids() {
        let levels = parse(["V", "D", "I", "W", "E", "F", "A"].map { "01-02 03:04:05.006 shell 1 2 \($0) t: m" }).compactMap { $0?.level }
        #expect(levels == [.verbose, .debug, .info, .warn, .error, .fatal, .fatal])
        let uids = parse(["u0_a123", "u10_a5", "system", "alien"].map { "01-02 03:04:05.006 \($0) 1 2 I t: m" }).map { $0?.uid }
        #expect(uids == [10_123, 1_010_005, 1000, nil])
    }

    @Test func paddedTagsEmptyMessagesAndIds() {
        let e = parse([
            "11-08 00:02:44.654 shell  7867  7867 I adbd    : starting",
            "11-08 00:02:44.654  1000 1 1 W Tag with spaces: x",
            "11-08 00:02:44.654  1000 1 1 D EmptyTag:",
        ])
        #expect(e[0]?.tag == "adbd" && e[0]?.message == "starting" && e[0]?.uid == 2000)
        #expect(e[1]?.tag == "Tag with spaces")
        #expect(e[2]?.tag == "EmptyTag" && e[2]?.message == "")
        #expect((e[0]?.id ?? -1) < (e[1]?.id ?? -1))
    }

    @Test func notLogLinesAreNil() {
        let junk = ["--------- beginning of main", "", "11-08", "13-40 00:00:00.000 1 1 1 I t: m", "11-08 00:02:44.264  1000 x 1 I t: m",
                    "11-08 00:02:44.264  1000 1 1 Q t: m", String(repeating: "\u{0}", count: 50)]
        #expect(parse(junk).allSatisfy { $0 == nil })
        let long = parse(["11-08 00:02:44.264  1000 1 1 I t: " + String(repeating: "x", count: 50_000)])[0]
        #expect((long?.message.count ?? 0) <= LogParser.maxMessage)
    }
}

@Suite struct AndroidLogClassifierTests {
    private func run(_ lines: [String]) -> [LogEntry] {
        var p = parser()
        var c = LogClassifier()
        return lines.compactMap { line in
            guard var e = p.parse(Substring(line)) else { return nil }
            c.classify(&e)
            return e
        }
    }

    @Test func javaCrashGroupsItsFrames() {
        let e = run([
            "11-08 00:00:00.000 10123 100 100 E AndroidRuntime: FATAL EXCEPTION: main",
            "11-08 00:00:00.000 10123 100 100 E AndroidRuntime: Process: com.example.app, PID: 100",
            "11-08 00:00:00.000 10123 100 100 E AndroidRuntime: java.lang.IllegalStateException: boom",
            "11-08 00:00:00.000 10123 100 100 E AndroidRuntime: \tat com.example.app.Main.onCreate(Main.java:12)",
            "11-08 00:00:00.000 10123 100 100 E AndroidRuntime: Caused by: java.lang.NullPointerException",
            "11-08 00:00:00.000 10123 100 100 E AndroidRuntime: \t... 7 more",
            "11-08 00:00:01.000 10123 100 100 I Other: unrelated",
        ])
        #expect(e[0].kind == .javaCrash && e[0].group == e[0].id)
        #expect(e[1...5].allSatisfy { $0.group == e[0].id })
        #expect(e[3].kind == .stackFrame && e[4].kind == .stackFrame && e[5].kind == .stackFrame)
        #expect(e[6].group == nil && e[6].kind == .plain)
    }

    @Test func anrAndNativeCrash() {
        let e = run([
            "11-08 00:00:00.000 1000 50 60 E ActivityManager: ANR in com.example.app",
            "11-08 00:00:00.000 1000 50 60 E ActivityManager: Reason: Input dispatching timed out",
            "11-08 00:00:00.000 1000 70 70 F DEBUG   : *** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***",
            "11-08 00:00:00.000 1000 70 70 F DEBUG   : backtrace:",
        ])
        #expect(e[0].kind == .anr && e[1].group == e[0].id && e[1].effectiveLevel == .error)
        #expect(e[2].kind == .nativeCrash && e[3].group == e[2].id)
    }

    @Test func flutterErrorAtInfoBecomesAnErrorGroup() {
        let e = run([
            "11-08 00:00:00.000 10200 300 320 I flutter : ══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞════════════════",
            "11-08 00:00:00.000 10200 300 320 I flutter : The following assertion was thrown building Foo:",
            "11-08 00:00:00.000 10200 300 320 I flutter : #0      Foo.build (package:fake_app/foo.dart:12:3)",
            "11-08 00:00:00.000 10200 300 320 I flutter : #1      StatelessElement.build (package:flutter/src/widgets/framework.dart:5000:49)",
            "11-08 00:00:00.000 10200 300 320 I flutter : ════════════════════════════════════════════════════",
            "11-08 00:00:01.000 10200 300 320 I flutter : hello from print",
        ])
        #expect(e[0].kind == .flutterError && e[0].effectiveLevel == .error && e[0].level == .info)
        #expect(e[1...4].allSatisfy { $0.group == e[0].id && $0.effectiveLevel == .error })
        #expect(e[2].kind == .dartFrame)
        #expect(e[5].kind == .flutterOutput && e[5].group == nil && e[5].effectiveLevel == .info)
    }

    @Test func unhandledDartExceptionAndEflutter() {
        let e = run([
            "11-08 00:00:00.000 10200 300 320 E flutter : [ERROR:flutter/runtime/dart_vm_initializer.cc(41)] Unhandled Exception: Bad state",
            "11-08 00:00:00.000 10200 300 320 E flutter : #0      main (package:fake_app/main.dart:5:3)",
            "11-08 00:00:02.000 10200 301 330 E flutter : some error without a header",
        ])
        #expect(e[0].kind == .flutterError && e[1].kind == .dartFrame && e[1].group == e[0].id)
        #expect(e[2].kind == .flutterError)
    }

    @Test func vmServiceJsonAndLoneFrames() {
        let e = run([
            "11-08 00:00:00.000 10200 300 320 I flutter : The Dart VM service is listening on http://127.0.0.1:43123/AbCd=/",
            "11-08 00:00:00.000 10200 300 320 D Net     : {\"status\": 200, \"ok\": true}",
            "11-08 00:00:00.000 10200 300 320 W System.err: \tat com.example.app.Net.get(Net.java:3)",
        ])
        #expect(e[0].kind == .vmService)
        #expect(LogClassifier.vmServiceURL(e[0].message)?.absoluteString == "http://127.0.0.1:43123/AbCd=/")
        #expect(e[1].kind == .json)
        #expect(e[2].kind == .stackFrame && e[2].effectiveLevel == .warn)
    }

    @Test func appFramesAndProcessStarts() {
        #expect(LogClassifier.isAppFrame("\tat com.example.app.Main.run(Main.java:1)", packages: ["com.example.app"]))
        #expect(!LogClassifier.isAppFrame("\tat android.os.Looper.loop(Looper.java:1)", packages: ["com.example.app"]))
        #expect(LogClassifier.isAppFrame("#0 main (package:app/main.dart:1:1)", packages: ["com.example.app"]))
        let start = run(["11-08 00:00:00.000 1000 50 60 I ActivityManager: Start proc 4242:com.example.app:remote/u0a123 for service"])[0]
        let found = LogClassifier.processStart(start)
        #expect(found?.pid == 4242 && found?.process == "com.example.app:remote")
    }
}
