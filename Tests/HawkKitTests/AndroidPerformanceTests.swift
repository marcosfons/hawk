import HawkKit
import Testing

@Suite struct AndroidPerformanceTests {
    @Test func sampleFromOneTick() {
        let s = PerformanceCapture.sample([
            "psi": "some avg10=4.25 avg60=4.30 avg300=5.68 total=1\nfull avg10=0.00 avg60=0 avg300=0 total=0\nsome avg10=12.50 avg60=0 avg300=0 total=1\nfull avg10=1 avg60=0 avg300=0 total=0\nsome avg10=0.00 avg60=0 avg300=0 total=1\n",
            "freq": "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq:1000000\n/sys/devices/system/cpu/cpu7/cpufreq/scaling_cur_freq:3000000\n",
            "thermal": "Thermal Status: 2\n",
            "mem": "                TOTAL PSS:   123456            TOTAL RSS:   200000      TOTAL SWAP PSS:     10\n",
        ], t: 3)
        #expect(s.t == 3 && s.cpuPressure == 0.0425 && s.memoryPressure == 0.125 && s.ioPressure == 0)
        #expect(s.maxMHz == 3000 && s.avgMHz == 2000 && s.thermal == 2 && s.pssKB == 123_456)
    }

    @Test func expensiveReadsEveryFifthSecond() {
        #expect(Set(PerformanceCapture.parts(tick: 1, package: "com.example.app").keys) == ["psi", "freq"])
        #expect(PerformanceCapture.parts(tick: 5, package: "com.example.app")["mem"] == "dumpsys meminfo 'com.example.app' 2>/dev/null | grep -m1 'TOTAL PSS'")
        #expect(PerformanceCapture.parts(tick: 5, package: "bad name")["mem"] == nil)
        #expect(PerformanceCapture.gfxinfo("com.example.app", reset: true) == "dumpsys gfxinfo 'com.example.app' reset")
    }

    @Test func frameStats() {
        let f = FrameStats.parse("""
        ** Graphics info for pid 1234 [com.example.app] **
        Stats since: 123ns
        Total frames rendered: 1200
        Janky frames: 60 (5.00%)
        50th percentile: 8ms
        90th percentile: 14ms
        95th percentile: 19ms
        99th percentile: 42ms
        Total frames rendered: 5
        """)
        #expect(f.total == 1200 && f.janky == 60 && f.jankyShare == 0.05 && f.p50 == 8 && f.p99 == 42)
        #expect(FrameStats.parse("nothing").total == nil)
    }

    @Test func downsampleKeepsShapeAndCap() {
        let points = (0..<1000).map { (t: Double($0), v: Double($0 % 10)) }
        let d = Timeline.downsample(points, max: 120)
        #expect(d.count == 120)
        #expect(d.first!.t < d.last!.t)
        #expect(abs(d.map(\.v).reduce(0, +) / 120 - 4.5) < 0.5)
        #expect(Timeline.downsample(Array(points.prefix(10)), max: 120).count == 10)
    }
}
