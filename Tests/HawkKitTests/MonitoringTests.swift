import HawkKit
import Foundation
import Testing

private func snapshot(soc: Double? = nil, onAC: Bool = true, freeGB: Double = 100) -> Snapshot {
    var s = Snapshot()
    if let soc { s.temps.soc = [soc] }
    var p = PowerInfo()
    p.onAC = onAC
    s.power = p
    return s
}

@Suite struct AlertTests {
    @Test func aConditionMustHoldForItsSustainTime() {
        let m = AlertMonitor()
        var settings = AlertSettings()
        settings.chipCelsius = 90
        let t0 = Date()
        #expect(m.evaluate(snapshot(soc: 95), processes: nil, appWatts: [:], settings: settings, now: t0).isEmpty)
        #expect(m.evaluate(snapshot(soc: 95), processes: nil, appWatts: [:], settings: settings, now: t0 + 30).isEmpty)
        #expect(m.evaluate(snapshot(soc: 95), processes: nil, appWatts: [:], settings: settings, now: t0 + 61).count == 1)
    }

    @Test func aBlipResetsTheClock() {
        let m = AlertMonitor()
        let t0 = Date()
        _ = m.evaluate(snapshot(soc: 99), processes: nil, appWatts: [:], settings: AlertSettings(), now: t0)
        _ = m.evaluate(snapshot(soc: 50), processes: nil, appWatts: [:], settings: AlertSettings(), now: t0 + 30)
        #expect(m.evaluate(snapshot(soc: 99), processes: nil, appWatts: [:], settings: AlertSettings(), now: t0 + 61).isEmpty)
    }

    @Test func alertsRespectTheCooldown() {
        let m = AlertMonitor()
        let t0 = Date()
        _ = m.evaluate(snapshot(soc: 99), processes: nil, appWatts: [:], settings: AlertSettings(), now: t0)
        #expect(m.evaluate(snapshot(soc: 99), processes: nil, appWatts: [:], settings: AlertSettings(), now: t0 + 61).count == 1)
        #expect(m.evaluate(snapshot(soc: 99), processes: nil, appWatts: [:], settings: AlertSettings(), now: t0 + 600).isEmpty)
    }

    @Test func aGrowingProcessIsReportedAfterFiveMinutes() {
        let m = AlertMonitor()
        let leaky = [ProcessStat(pid: 42, name: "leaky", memory: 3_000_000_000, growth: 200_000_000)]
        let t0 = Date()
        #expect(m.evaluate(snapshot(), processes: leaky, appWatts: [:], settings: AlertSettings(), now: t0).isEmpty)
        #expect(m.evaluate(snapshot(), processes: nil, appWatts: [:], settings: AlertSettings(), now: t0 + 200).isEmpty)
        #expect(m.evaluate(snapshot(), processes: leaky, appWatts: [:], settings: AlertSettings(), now: t0 + 301).first?.title == "leaky keeps growing")
    }

    @Test func batteryDrainOnlyCountsOnBattery() {
        let m = AlertMonitor()
        let t0 = Date()
        _ = m.evaluate(snapshot(onAC: true), processes: nil, appWatts: ["Chrome": 9], settings: AlertSettings(), now: t0)
        #expect(m.evaluate(snapshot(onAC: true), processes: nil, appWatts: ["Chrome": 9], settings: AlertSettings(), now: t0 + 400).isEmpty)
        _ = m.evaluate(snapshot(onAC: false), processes: nil, appWatts: ["Chrome": 9], settings: AlertSettings(), now: t0 + 500)
        #expect(m.evaluate(snapshot(onAC: false), processes: nil, appWatts: ["Chrome": 9], settings: AlertSettings(), now: t0 + 801).count == 1)
    }
}

@Suite struct EnergyTests {
    let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)"

    @Test func helpersCountTowardTheirApp() {
        #expect(EnergyTracker.app(ProcessStat(pid: 1, name: "Google Chrome Helper (Renderer)", path: chrome)) == "Google Chrome")
        #expect(EnergyTracker.app(ProcessStat(pid: 2, name: "mds_stores", path: "/System/Library/mds_stores")) == "mds_stores")
    }

    @Test func energyIsTheDeltaBetweenSamples() {
        let t = EnergyTracker(stateURL: nil)
        let now = Date()
        t.record([ProcessStat(pid: 1, name: "a", path: chrome, start: 5, energy: 100)], systemWatts: 10, onAC: true, now: now)
        t.record([ProcessStat(pid: 1, name: "a", path: chrome, start: 5, energy: 160),
                  ProcessStat(pid: 2, name: "b", path: chrome, start: 9, energy: 999)], systemWatts: 10, onAC: true, now: now + 10)
        // The first sight of a process is only a baseline: 999 J of b's history is not counted.
        #expect(t.usage(.hour, now: now + 10).first { $0.id == "Google Chrome" }?.joules == 60)
    }

    @Test func sinceUnpluggedResetsOnTheCharger() {
        let t = EnergyTracker(stateURL: nil)
        let now = Date()
        t.record([ProcessStat(pid: 1, name: "a", start: 1, energy: 0)], systemWatts: 10, onAC: false, now: now)
        t.record([ProcessStat(pid: 1, name: "a", start: 1, energy: 50)], systemWatts: 10, onAC: false, now: now + 5)
        #expect(t.usage(.sinceUnplugged, now: now + 5).first?.joules == 50)
        t.record([ProcessStat(pid: 1, name: "a", start: 1, energy: 70)], systemWatts: 10, onAC: true, now: now + 10)
        #expect(t.unpluggedAt == nil)
        #expect(t.usage(.sinceUnplugged, now: now + 10).allSatisfy { $0.joules == 0 })
    }

    @Test func quittingAnAppGivesBackTime() {
        var p = PowerInfo()
        p.maxCapacity = 5000; p.voltage = 12; p.percent = 50          // 30 Wh left
        #expect(BatteryEstimate.minutes(p, watts: 10) == 180)
        #expect(BatteryEstimate.gain(p, systemWatts: 10, appWatts: 5) == 180)
    }

    @Test func holdingChargeIsDescribed() {
        var p = PowerInfo()
        p.onAC = true; p.percent = 80; p.notChargingReason = 0x1000000
        #expect(ChargeStatus.describe(p, batteryTemp: 30).title == "Holding at 80%")
    }
}

@Suite struct NetworkParsingTests {
    @Test func nettopLinesParse() {
        let rows = NetworkSampler.parse(",bytes_in,bytes_out,\nGoogle Chrome H.1234,5484,11848,\nmDNSResponder.676,411487293,54900674,\n")
        #expect(rows.count == 2)
        #expect(rows[0].pid == 1234 && rows[0].name == "Google Chrome H" && rows[0].rx == 5484 && rows[0].tx == 11848)
    }
}
