import Foundation
import HawkKit
import Testing

private func entries(_ lines: [String]) -> [LogEntry] {
    var p = LogParser(now: Date(timeIntervalSince1970: 1_800_000_000))
    var c = LogClassifier()
    return lines.compactMap { line in
        guard var e = p.parse(Substring(line)) else { return nil }
        c.classify(&e)
        return e
    }
}

private let lines = entries([
    "11-08 10:00:00.000 10100 100 100 D Location: fix 1",                                     // 0 app A
    "11-08 10:00:01.000 10100 100 100 W chatty  : uid=10100 identical 3 lines",                // 1 app A
    "11-08 10:00:02.000 10200 200 200 I flutter : hello",                                     // 2 app B
    "11-08 10:00:03.000 10200 200 200 I flutter : ══╡ EXCEPTION CAUGHT BY WIDGETS LIBRARY ╞══", // 3 app B error
    "11-08 10:00:04.000 1000 50 60 E ActivityManager: ANR in com.example.a",                   // 4 system
    "11-08 10:00:05.000 10100 300 300 E TSLocationManager: timeout connecting",                // 5 app A, new pid
])

private var context: LogFilter.Context {
    var c = LogFilter.Context()
    c.uidPackages = [10100: ["com.example.a"], 10200: ["com.example.b"]]
    c.mine = ["com.example.b"]
    c.now = lines.last!.time
    return c
}

private func shown(_ text: String, muted: Set<String> = []) -> [Int] {
    let f = LogFilter(parsing: text).compiled()
    var c = context
    c.muted = muted
    return lines.enumerated().filter { f.matches($0.element, c) }.map(\.offset)
}

@Suite struct AndroidLogFilterTests {
    @Test func everyKey() {
        #expect(shown("") == [0, 1, 2, 3, 4, 5])
        #expect(shown("package:com.example.a") == [0, 1, 5])
        #expect(shown("package:mine") == [2, 3])
        #expect(shown("tag:loc") == [0, 5])
        #expect(shown("-tag:chatty") == [0, 2, 3, 4, 5])
        #expect(shown("tag=:flutter") == [2, 3])
        #expect(shown("tag~:^TS.*") == [5])
        #expect(shown("level:warn") == [1, 3, 4, 5])
        #expect(shown("pid:200") == [2, 3])
        #expect(shown("message~:timeout|refused") == [5])
        #expect(shown("is:anr") == [4])
        #expect(shown("is:flutter-error") == [3])
        #expect(shown("age:2s") == [3, 4, 5])
        #expect(shown("fix") == [0])
        #expect(shown("\"identical 3\"") == [1])
    }

    @Test func andAndOr() {
        #expect(shown("package:com.example.a level:error") == [5])
        #expect(shown("tag=:TSLocationManager | tag=:flutter") == [2, 3, 5])
        #expect(shown("is:crash | is:anr") == [4])
    }

    @Test func mutedTagsApplyToEveryFilter() {
        #expect(shown("package:com.example.a", muted: ["chatty"]) == [0, 5])
    }

    @Test func invalidTokensAreReportedAndIgnored() {
        let f = LogFilter(parsing: "level:loud pid:abc tag~:( is:nonsense package:bad name age:5x tag:ok")
        #expect(f.invalid == ["level:loud", "pid:abc", "tag~:(", "is:nonsense", "package:bad", "age:5x"])
        #expect(f.text == "name tag:ok")
        #expect(LogFilter(parsing: "url:http://x").alternatives == [[LogFilter.Term(nil, "url:http://x")]])
    }

    @Test func textRoundTrip() {
        for text in ["package:com.example.a level:warn", "tag=:flutter | -tag:chatty", "\"two words\" is:crash", "message~:a.b"] {
            #expect(LogFilter(parsing: LogFilter(parsing: text).text) == LogFilter(parsing: text))
        }
    }

    @Test func chipsWriteTheBarAndTheBarLightsTheChips() {
        let typed = LogFilter(parsing: "level:warn -tag:chatty")
        #expect(typed.minimumLevel == .warn)
        let clicked = typed.setting(minimumLevel: .error)
        #expect(clicked.text == "level:error -tag:chatty")
        #expect(clicked.setting(minimumLevel: nil).text == "-tag:chatty")

        var apps = LogFilter().toggling(package: "com.example.a")
        #expect(apps.text == "package:com.example.a")
        apps = apps.toggling(package: "com.example.b")
        #expect(apps.packages == ["com.example.a", "com.example.b"])
        #expect(apps.text == "package:com.example.a | package:com.example.b")
        #expect(apps.toggling(package: "com.example.a").text == "package:com.example.b")

        let kinds = LogFilter(parsing: "package:com.example.a").toggling(kind: "crash")
        #expect(kinds.has(kind: "crash") && kinds.text == "package:com.example.a is:crash")
        #expect(!kinds.toggling(kind: "crash").has(kind: "crash"))
    }

    @Test func followsAnAppAcrossRestartsByProcessStart() {
        var c = context
        c.uidPackages = [:]
        c.pidProcess = [300: "com.example.a:remote"]
        let f = LogFilter(parsing: "package:com.example.a").compiled()
        #expect(f.matches(lines[5], c))
        #expect(!f.matches(lines[0], c))
    }
}
