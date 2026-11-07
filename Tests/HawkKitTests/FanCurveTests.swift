import HawkKit
import Testing

@Suite struct FanCurveTests {
    let curve = FanCurve.balanced          // SoC 60→90, SSD 55→70, battery 37→43

    @Test func levelIsZeroAtStartAndOneAtFull() {
        #expect(curve.level(CurveTemps(soc: 60, ssd: nil, battery: nil)) == 0)
        #expect(curve.level(CurveTemps(soc: 75, ssd: nil, battery: nil)) == 0.5)
        #expect(curve.level(CurveTemps(soc: 99, ssd: nil, battery: nil)) == 1)
    }

    @Test func hottestSourceRelativeToItsThresholdsWins() {
        // SoC is only at 10% of its range, the battery at 50% of its own.
        let t = CurveTemps(soc: 63, ssd: 40, battery: 40)
        #expect(curve.level(t) == 0.5)
        #expect(curve.driver(t) == .battery)
    }

    @Test func noSensorsMeansNoMargin() {
        #expect(curve.margin(CurveTemps(soc: nil, ssd: nil, battery: nil)) == nil)
    }

    @Test func rpmSpansTheFanRange() {
        #expect(FanCurve.rpm(level: 0, min: 2317, max: 7826) == 2317)
        #expect(FanCurve.rpm(level: 1, min: 2317, max: 7826) == 7826)
        #expect(FanCurve.rpm(level: 2, min: 2317, max: 7826) == 7826)
    }
}

@Suite struct CurveControllerTests {
    let curve = FanCurve.balanced

    func temps(_ soc: Double) -> CurveTemps { CurveTemps(soc: soc, ssd: nil, battery: nil) }

    @Test func staysWithMacOSBelowStart() {
        var c = CurveController()
        #expect(c.step(curve: curve, temps: temps(55), min: 2000, max: 8000, dt: 1) == nil)
    }

    @Test func engagesAtMinimumAtStart() {
        var c = CurveController()
        #expect(c.step(curve: curve, temps: temps(60), min: 2000, max: 8000, dt: 1) == 2000)
    }

    @Test func rampsUpNoFasterThanTheLimit() {
        var c = CurveController()
        _ = c.step(curve: curve, temps: temps(60), min: 2000, max: 8000, dt: 1)
        let next = c.step(curve: curve, temps: temps(90), min: 2000, max: 8000, dt: 1)
        #expect(next == 2000 + CurveController.rampUp)
    }

    @Test func rampsDownSlowly() {
        var c = CurveController()
        _ = c.step(curve: curve, temps: temps(90), min: 2000, max: 8000, dt: 100)   // reaches max
        let next = c.step(curve: curve, temps: temps(60), min: 2000, max: 8000, dt: 1)
        #expect(next == 8000 - CurveController.rampDown)
    }

    @Test func hysteresisKeepsFansOnJustBelowStart() {
        var c = CurveController()
        _ = c.step(curve: curve, temps: temps(61), min: 2000, max: 8000, dt: 1)
        #expect(c.step(curve: curve, temps: temps(58), min: 2000, max: 8000, dt: 1) != nil)
        #expect(c.step(curve: curve, temps: temps(55), min: 2000, max: 8000, dt: 1) == nil)
    }
}

@Suite struct ControlPolicyTests {
    func decide(_ s: ControlSettings, soc: Double = 80, onAC: Bool = true) -> (rpm: Double?, note: String?) {
        var c = CurveController()
        return ControlPolicy.decide(s, temps: CurveTemps(soc: soc, ssd: nil, battery: nil), onAC: onAC,
                                    min: 2317, max: 7826, dt: 1, controller: &c)
    }

    @Test func autoNeverRequestsASpeed() {
        #expect(decide(ControlSettings()).rpm == nil)
    }

    @Test func batteryHandsBackToMacOSByDefault() {
        var s = ControlSettings(); s.mode = .fixed
        let d = decide(s, onAC: false)
        #expect(d.rpm == nil)
        #expect(d.note != nil)
    }

    @Test func batteryCanBeOverridden() {
        var s = ControlSettings(); s.mode = .fixed; s.macOSOnBattery = false
        #expect(decide(s, onAC: false).rpm == 3000)
    }

    @Test func fixedIsClampedToTheFanRange() {
        var s = ControlSettings(); s.mode = .fixed; s.fixedRPM = 100
        #expect(decide(s).rpm == 2317)
        s.fixedRPM = 99_999
        #expect(decide(s).rpm == 7826)
    }
}
