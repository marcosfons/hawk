import Foundation
import HawkKit
import Testing

private let utc = TimeZone(identifier: "UTC")!

private let listing = """
Drop box contents: 796 entries
Max entries: 1000

2026-11-05 05:30:02 clockpackage (text, 46 bytes)
2026-11-05 08:37:18 data_app_crash (text, 1599 bytes)
2026-11-06 10:00:00 data_app_anr (text, 4000 bytes)
garbage
"""

private let entries = """
Drop box contents: 796 entries
Searching for: data_app_anr

========================================
2026-11-06 10:00:00 data_app_anr (text, 4000 bytes)
Process: com.example.app
PID: 4242
UID: 10123
Package: com.example.app v12 (1.2.0)
Foreground: Yes
Timestamp: 2026-11-06 10:00:00.250-0300
Subject: Input dispatching timed out (Waiting to send non-key event)

"main" prio=5 tid=1 Sleeping
  at java.lang.Thread.sleep(Native method)
  at com.example.app.Main.onClick(Main.java:42)
========================================
2026-11-05 08:37:18 data_app_crash (text, 1599 bytes)
Process: com.example.other
PID: 5906
UID: 10381
Package: com.example.other v3 (3)

java.lang.IllegalStateException: boom
\tat com.example.other.A.b(A.java:1)
"""

@Suite struct AndroidCrashTests {
    @Test func listingKeepsOnlyCrashTags() {
        let headers = DropBox.parseListing(listing, timeZone: utc)
        #expect(headers.map(\.tag) == ["data_app_crash", "data_app_anr"])
        #expect(headers[0].key == "2026-11-05 08:37:18 data_app_crash (text, 1599 bytes)")
    }

    @Test func entriesWithHeadersAndTrace() throws {
        let records = DropBox.parseEntries(entries, timeZone: utc)
        #expect(records.count == 2)
        let anr = try #require(records.first)
        #expect(anr.kind == .anr && anr.package == "com.example.app" && anr.pid == 4242 && anr.uid == 10123 && anr.foreground == true)
        #expect(anr.reason == "Input dispatching timed out (Waiting to send non-key event)")
        #expect(anr.body.hasPrefix("\"main\" prio=5") && anr.body.contains("Main.java:42"))
        #expect(abs(anr.date.timeIntervalSince1970 - 1_793_970_000.25) < 1)
        #expect(records[1].kind == .crash && records[1].reason == "java.lang.IllegalStateException: boom")
    }

    @Test func garbageAndTruncationAreSafe() {
        #expect(DropBox.parseEntries("========================================\nnot a header\n", timeZone: utc).isEmpty)
        let cut = String(entries.prefix(300))
        #expect(DropBox.parseEntries(cut, timeZone: utc).count <= 1)
        #expect(DropBox.parseListing(String(repeating: "x y z\n", count: 10_000)).isEmpty)
    }

    @Test func firstImportIsSilentAndLaterOnesAlertOnce() {
        var log = CrashLog()
        let old = DropBox.parseEntries(entries, timeZone: utc)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(log.add(old, now: now).isEmpty)             // history: imported, no alert
        #expect(log.records.count == 2)
        #expect(log.new(DropBox.parseListing(listing, timeZone: utc)).isEmpty)
        let newANR = CrashRecord(key: "2027-01-15 08:00:30 data_app_anr (text, 10 bytes)", tag: "data_app_anr", kind: .anr,
                                 date: now.addingTimeInterval(30), reason: "x", body: "")
        #expect(log.add([newANR], now: now.addingTimeInterval(60)).map(\.key) == [newANR.key])
        #expect(log.add([newANR], now: now.addingTimeInterval(120)).isEmpty)   // never twice
        #expect(log.counts()["com.example.app"]?.anrs == 1)
    }

    @Test func recordsAreCapped() {
        var log = CrashLog()
        let many = (0..<700).map { CrashRecord(key: "k\($0)", tag: "data_app_crash", kind: .crash, date: Date(timeIntervalSince1970: Double($0)), reason: "", body: "") }
        _ = log.add(many, now: Date())
        #expect(log.records.count == CrashLog.maxRecords)
        #expect(log.records.first?.key == "k699")
    }

    @Test func logcatCommandIsQuoted() {
        let cmd = DropBox.logcatBefore(Date(timeIntervalSince1970: 1_800_000_030), timeZone: utc)
        #expect(cmd.contains("-t '01-15 08:00:00.000'") && cmd.hasSuffix("| head -n 400"))
    }
}
