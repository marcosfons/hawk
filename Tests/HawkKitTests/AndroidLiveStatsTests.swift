import HawkKit
import Testing

private func proc(cpu0: [Int64], cpu1: [Int64], rx: Int64, tx: Int64) -> String {
    let total = zip(cpu0, cpu1).map { $0 + $1 }
    return """
    cpu  \(total.map(String.init).joined(separator: " "))
    cpu0 \(cpu0.map(String.init).joined(separator: " "))
    cpu1 \(cpu1.map(String.init).joined(separator: " "))
    intr 1 2 3
    MemTotal:        8000000 kB
    MemAvailable:    3000000 kB
    SwapTotal:       4000000 kB
    SwapFree:        3500000 kB
    Inter-|   Receive
     face |bytes    packets
        lo: 999 1 0 0 0 0 0 0 999 1 0 0 0 0 0 0
     wlan0: \(rx) 10 0 0 0 0 0 0 \(tx) 10 0 0 0 0 0 0
    """
}

@Suite struct AndroidLiveStatsTests {
    @Test func ratesNeedTwoReadings() {
        var s = LiveSampler()
        let first = s.update(["proc": proc(cpu0: [100, 0, 100, 800, 0, 0, 0, 0], cpu1: [0, 0, 0, 1000, 0, 0, 0, 0], rx: 1000, tx: 500)], now: 0)
        #expect(first.cores.isEmpty && first.rxRate == nil)
        #expect(first.memTotalKB == 8_000_000 && first.memAvailableKB == 3_000_000 && first.swapFreeKB == 3_500_000)
        let second = s.update(["proc": proc(cpu0: [150, 0, 150, 900, 0, 0, 0, 0], cpu1: [0, 0, 0, 1100, 0, 0, 0, 0], rx: 4000, tx: 1100)], now: 3)
        #expect(second.cores == [0.5, 0])
        #expect(abs((second.total ?? 0) - 1.0 / 3) < 1e-9)
        #expect(second.rxRate == 1000 && second.txRate == 200)
    }

    @Test func frequenciesTemperaturesAndTop() {
        var s = LiveSampler()
        let out = s.update([
            "freq": "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq:1959000\n/sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq:3000000\n",
            "thermal": "\tTemperature{mValue=29.2, mType=0, mName=AP, mStatus=0}\n\tTemperature{mValue=27.4, mType=2, mName=BAT, mStatus=0}\n\tTemperature{mValue=999, mType=2, mName=BAD, mStatus=0}\n",
            "top": "Tasks: 800 total\n  PID %CPU   RES NAME\n 1234 12.5 300M com.example.app\n 99 3.0 20M surfaceflinger\n",
        ], now: 0)
        #expect(out.frequencyMHz == [0: 1959, 7: 3000])
        #expect(out.temperatures.map(\.name) == ["AP", "BAT"] && out.temperatures.first?.celsius == 29.2)
        #expect(out.top.map(\.name) == ["com.example.app", "surfaceflinger"] && out.top.first?.cpu == 12.5)
    }

    @Test func scheduleKeepsTheExpensiveReadsRare() {
        let keys = (0..<30).map { Set(LiveSampler.parts(tick: $0).keys) }
        #expect(keys.filter { $0.contains("proc") }.count == 30)
        #expect(keys.filter { $0.contains("thermal") }.count == 10)
        #expect(keys.filter { $0.contains("top") }.count == 3)
    }

    @Test func countersGoingBackwardsAreIgnored() {
        var s = LiveSampler()
        _ = s.update(["proc": proc(cpu0: [100, 0, 100, 800, 0, 0, 0, 0], cpu1: [0, 0, 0, 1000, 0, 0, 0, 0], rx: 5000, tx: 5000)], now: 0)
        let after = s.update(["proc": proc(cpu0: [10, 0, 10, 80, 0, 0, 0, 0], cpu1: [0, 0, 0, 100, 0, 0, 0, 0], rx: 10, tx: 10)], now: 3)
        #expect(after.rxRate == nil)
        #expect(after.cores == [0, 0])
    }
}
