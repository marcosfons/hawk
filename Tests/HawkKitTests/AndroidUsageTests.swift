import Foundation
import HawkKit
import Testing

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// 2027-01-15 12:00 UTC.
private let noon = Date(timeIntervalSince1970: 1_800_014_400)

private func record(_ daysAgo: Int, uid: Int, _ t: NetRecord.Transport, fg: Bool = true, rx: Int64, tx: Int64 = 0) -> NetRecord {
    let start = utc.date(byAdding: .day, value: -daysAgo, to: utc.startOfDay(for: noon))!
    return NetRecord(transport: t, windowStart: start, uid: uid, foreground: fg, rx: rx, tx: tx)
}

@Suite struct AndroidUsageTests {
    @Test func batteryCheckin() {
        let text = """
        9,0,l,pws,4900,2248.5,2248,2300
        9,0,l,pwi,scrn,290,1,0,0
        9,10100,l,pwi,uid,12.5,0,0,0
        9,10100,l,pwi,uid,0.5,0,0,0
        9,10101,l,pwi,uid,nan,0,0,0
        9,10100,l,nt,100,50,1000,500,1,1,1,1
        9,10102,l,nt,-1,0,0,0,0,0,0,0
        garbage,line
        """
        let b = BatteryCheckin.parse(text)
        #expect(b.capacity == 4900 && b.drain == 2248.5)
        #expect(b.mAh == [10100: 13])
        #expect(b.network[10100]?.mobile == 150 && b.network[10100]?.wifi == 1500)
        #expect(b.network[10102] == nil)
    }

    @Test func meminfoAddsAnAppsProcesses() {
        let text = """
        Total PSS by process:
            536,438K: com.example.chat (pid 31141 / activities)
             12,000K: com.example.chat:push (pid 31150)
            381,338K: system (pid 2000)
              1,024K: com.example.game (pid 4000)
        """
        #expect(Meminfo.parse(text) == ["com.example.chat": 548_438, "com.example.game": 1024])
    }

    @Test func firstFetchIsAHundredDaysThenOnlyNewDays() throws {
        var h = UsageHistory()
        let first = h.nextFetch(now: noon, calendar: utc)
        guard case .net(let from, let to, let step) = first else { Issue.record("not net"); return }
        #expect(utc.dateComponents([.day], from: from, to: utc.startOfDay(for: noon)).day == 100)
        #expect(to == noon && step == 86_400)
        h.merge([record(0, uid: 10100, .wifi, rx: 10), record(1, uid: 10100, .mobile, fg: false, rx: 5, tx: 5)], fetched: first, now: noon, calendar: utc)
        #expect(h.days.count == 101)
        let later = noon.addingTimeInterval(2 * 86_400)
        guard case .net(let from2, _, _) = h.nextFetch(now: later, calendar: utc) else { return }
        #expect(from2 == utc.startOfDay(for: noon))   // today was not complete: fetched again
    }

    @Test func totalsOverAPeriod() {
        var h = UsageHistory()
        let fetch = h.nextFetch(now: noon, calendar: utc)
        h.merge([
            record(0, uid: 10100, .wifi, rx: 100, tx: 10),
            record(3, uid: 10100, .mobile, fg: false, rx: 40),
            record(20, uid: 10100, .wifi, rx: 1000),
            record(0, uid: -5, .mobile, rx: 7),
        ], fetched: fetch, now: noon, calendar: utc)
        #expect(h.totals(lastDays: 1, now: noon, calendar: utc)[10100] == DayUsage(wifi: 110, mobile: 0, background: 0))
        #expect(h.totals(lastDays: 7, now: noon, calendar: utc)[10100] == DayUsage(wifi: 110, mobile: 40, background: 40))
        #expect(h.totals(lastDays: 30, now: noon, calendar: utc)[10100]?.wifi == 1110)
    }

    @Test func refetchReplacesDays() {
        var h = UsageHistory()
        let fetch = h.nextFetch(now: noon, calendar: utc)
        h.merge([record(0, uid: 10100, .wifi, rx: 100)], fetched: fetch, now: noon, calendar: utc)
        let again = h.nextFetch(now: noon, calendar: utc)
        h.merge([record(0, uid: 10100, .wifi, rx: 300)], fetched: again, now: noon, calendar: utc)
        #expect(h.totals(lastDays: 1, now: noon, calendar: utc)[10100]?.wifi == 300)
    }

    @Test func historyIsCapped() {
        var h = UsageHistory()
        var now = noon
        for _ in 0..<6 {
            h.merge([], fetched: .net(from: now.addingTimeInterval(-100 * 86_400), to: now, step: 86_400), now: now, calendar: utc)
            now = now.addingTimeInterval(100 * 86_400)
        }
        #expect(h.days.count == UsageHistory.maxDays)
    }

    @Test func rowsGroupSharedUidsAndNameSpecialOnes() {
        var index = PackageIndex.parse(["all": """
            package:com.example.chat versionCode:1 uid:10100
            package:android versionCode:1 uid:1000
            package:com.android.settings versionCode:1 uid:1000
            """])
        index.setLabel("Fake Chat", for: "com.example.chat")
        let battery = BatteryCheckin.parse("9,10100,l,pwi,uid,30,0,0,0\n9,1000,l,pwi,uid,10,0,0,0\n9,10100,l,nt,1,1,2,2,0,0,0,0\n")
        let rows = UsageTable.rows(index: index, history: nil, battery: battery, memory: ["com.example.chat": 2048], period: .today, now: noon)
        #expect(rows.map(\.title) == ["Fake Chat", "Android system"])
        #expect(rows[0].batteryShare == 0.75 && rows[0].data == 6 && rows[0].memoryKB == 2048)
        var h = UsageHistory()
        h.merge([record(0, uid: -5, .mobile, rx: 9), record(0, uid: -4, .wifi, rx: 1)], fetched: h.nextFetch(now: noon, calendar: utc), now: noon, calendar: utc)
        let special = UsageTable.rows(index: index, history: h, battery: nil, memory: [:], period: .today, now: noon, calendar: utc)
        #expect(Set(special.map(\.title)) == ["Hotspot", "Removed apps"])
    }
}
