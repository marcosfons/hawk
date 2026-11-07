import Foundation
import HawkKit

// MARK: - Formatting helpers

func bytes(_ b: Double) -> String { Format.bytes(b) }
func gb(_ b: UInt64) -> String { String(format: "%.1f", Double(b) / 1_073_741_824) }
func pct(_ x: Double) -> String { String(format: "%3.0f%%", x * 100) }
func color(_ s: String, _ level: Double, warn: Double, hot: Double) -> String {
    let c = level >= hot ? "31" : level >= warn ? "33" : "32"
    return "\u{1B}[\(c)m\(s)\u{1B}[0m"
}
func bar(_ x: Double, width: Int = 20) -> String {
    let n = Int((min(max(x, 0), 1) * Double(width)).rounded())
    return color(String(repeating: "█", count: n), x, warn: 0.6, hot: 0.85) + String(repeating: "·", count: width - n)
}
func spark(_ xs: [Double]) -> String {
    let s = Array("▁▂▃▄▅▆▇█")
    return String(xs.map { s[min(Int($0 * Double(s.count)), s.count - 1)] })
}
func temp(_ c: Double?) -> String {
    guard let c else { return "  -  " }
    return color(String(format: "%.1f°", c), c, warn: 70, hot: 90)
}
func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[0m" }
func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
func hm(_ m: Int?) -> String { m.map { String(format: "%d:%02d", $0 / 60, $0 % 60) } ?? "—" }

// MARK: - Commands

/// `hawk dump [prefix]` — every numeric SMC key plus every HID temperature sensor.
func dump(prefix: String?) {
    guard let smc = SMC() else { print("Cannot open AppleSMC"); return }
    let keys = smc.allKeys()
    print("SMC exposes \(keys.count) keys\(prefix.map { " (showing \($0)*)" } ?? "")\n")
    for k in keys where prefix.map(k.hasPrefix) ?? true {
        guard let (t, b) = smc.read(k) else { continue }
        let v = SMC.decode(type: t, bytes: b).map { String(format: "%.3f", $0) } ?? b.map { String(format: "%02x", $0) }.joined()
        print("\(k)  [\(t)]  \(v)")
    }
    print("\nHID temperature sensors:")
    for (n, v) in HIDSensors().read() { print(String(format: "  %-24@ %6.1f °C", n as NSString, v)) }
}

/// `hawk watch [-i seconds]` — live dashboard.
func watch(interval: Double) {
    let sampler = Sampler()
    signal(SIGINT) { _ in print("\u{1B}[?25h"); exit(0) }   // restore cursor
    print("\u{1B}[?25l\u{1B}[2J", terminator: "")
    while true {
        Thread.sleep(forTimeInterval: interval)
        render(sampler.sample(), interval: interval)
    }
}

func render(_ s: Snapshot, interval: Double) {
    var o: [String] = []
    let t = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    o.append(dim("hawk watch · every \(interval)s · \(t) · ctrl-c to quit"))
    o.append("")
    o.append("CPU    \(bar(s.cpuTotal)) \(pct(s.cpuTotal))   E \(pct(s.eUsage)) \(spark(Array(s.cores.prefix(s.eCores))))   P \(pct(s.pUsage)) \(spark(Array(s.cores.dropFirst(s.eCores))))")
    if let g = s.gpu { o.append("GPU    \(bar(g)) \(pct(g))") }
    let soc = s.temps.soc
    o.append("TEMP   SoC \(temp(mean(soc))) avg  \(temp(soc.max())) max   SSD \(temp(s.temps.ssd.max()))   Battery \(temp(s.temps.battery.max()))")
    let fans = s.fans.map { f in
        let mode = f.mode == 1 ? "manual" : "auto"
        return f.actual < 1 ? "fan\(f.index) off (\(mode))" : String(format: "fan%d %.0f rpm (%@)", f.index, f.actual, mode)
    }
    if let f = s.fans.first { o.append("FANS   \(fans.joined(separator: "   "))   " + dim(String(format: "range %.0f–%.0f", f.min, f.max))) }
    if let w = s.systemPower { o.append(String(format: "POWER  whole Mac %.1f W", w) + dim("  (live, SMC PSTR)")) }
    o.append("")
    if let m = s.memory {
        let used = Double(m.used) / Double(m.total)
        o.append("MEM    \(bar(used)) \(gb(m.used))/\(gb(m.total)) GB   pressure \(color(pct(m.pressure), m.pressure, warn: 0.5, hot: 0.8))")
        o.append("       " + dim("app \(gb(m.app))  wired \(gb(m.wired))  compressed \(gb(m.compressed))  cached \(gb(m.cached))  free \(gb(m.free))"))
        let sw = m.swapTotal > 0 ? Double(m.swapUsed) / Double(m.swapTotal) : 0
        o.append("SWAP   \(bar(sw)) \(gb(m.swapUsed))/\(gb(m.swapTotal)) GB   in \(bytes(s.swapInRate))/s  out \(bytes(s.swapOutRate))/s")
    }
    o.append("")
    for v in s.volumes {
        let used = Double(v.total - min(v.available, v.total)) / Double(v.total)
        o.append("DISK   \(bar(used)) \(pct(used))  \(bytes(Double(v.available))) free of \(bytes(Double(v.total)))  " + dim(v.name))
    }
    // Internal disk always; other disks (external drives, mounted images) only while active.
    for (n, r, w) in s.disks where n == "disk0" || r + w > 0 {
        o.append("  I/O  \(n)  read \(bytes(r))/s  write \(bytes(w))/s")
    }
    o.append("")
    let active = s.interfaces.filter { $0.0.hasPrefix("en") || $0.1 + $0.2 > 0 }
    let rx = active.map(\.1).reduce(0, +), tx = active.map(\.2).reduce(0, +)
    o.append("NET    ↓ \(bytes(rx))/s   ↑ \(bytes(tx))/s   " + dim(active.filter { $0.1 + $0.2 > 0 }.map { "\($0.0) ↓\(bytes($0.1))/s ↑\(bytes($0.2))/s" }.joined(separator: "  ")))
    o.append("")
    if let p = s.power {
        let state = p.fullyCharged ? "full" : p.isCharging ? "charging, \(hm(p.minutesRemaining)) to full"
            : p.onAC ? "on AC, not charging (reason \(p.notChargingReason))" : "on battery, \(hm(p.minutesRemaining)) left"
        o.append("BATT   \(bar(Double(p.percent) / 100)) \(p.percent)%  \(state)")
        o.append(String(format: "       battery %+.1f W  (%.2f V × %+.2f A)   ", p.batteryPower, p.voltage, p.amperage) + dim("battery gauge refreshes every ~30–60 s"))
        o.append("       " + dim(String(format: "health %.0f%% (%d/%d mAh) · %d cycles", p.health * 100, p.maxCapacity, p.designCapacity, p.cycles)))
        if let name = p.adapterName {
            o.append(String(format: "CHARGER %@ · %d W negotiated (%.0f V × %.2f A) · drawing %.1f W", name, p.adapterWatts, p.adapterVolts, p.adapterAmps, p.adapterIn))
        } else { o.append("CHARGER none connected") }
    }
    print("\u{1B}[H" + o.map { $0 + "\u{1B}[K" }.joined(separator: "\n") + "\u{1B}[J", terminator: "")
    fflush(stdout)
}

/// `hawk log [-i seconds]` — CSV on stdout for experiments (fan curve, power cost).
func log(interval: Double) {
    let sampler = Sampler()
    print("time,cpu,gpu,soc_avg,soc_max,ssd,battery_temp,fan0_rpm,fan1_rpm,system_w,battery_w,percent,on_ac")
    let start = Date()
    while true {
        Thread.sleep(forTimeInterval: interval)
        let s = sampler.sample()
        let p = s.power
        let f = s.fans.map { String(format: "%.0f", $0.actual) } + ["", ""]
        let row: [String] = [
            String(format: "%.1f", Date().timeIntervalSince(start)),
            String(format: "%.3f", s.cpuTotal), String(format: "%.3f", s.gpu ?? 0),
            String(format: "%.1f", mean(s.temps.soc) ?? 0), String(format: "%.1f", s.temps.soc.max() ?? 0),
            String(format: "%.1f", s.temps.ssd.max() ?? 0), String(format: "%.1f", s.temps.battery.max() ?? 0),
            f[0], f[1],
            String(format: "%.2f", s.systemPower ?? p?.systemLoad ?? 0), String(format: "%.2f", p?.batteryPower ?? 0),
            "\(p?.percent ?? 0)", (p?.onAC ?? false) ? "1" : "0",
        ]
        print(row.joined(separator: ","))
        fflush(stdout)
    }
}

// MARK: - Fan control (root)

nonisolated(unsafe) var stopRequested: Int32 = 0

func requireRoot(_ cmd: String) {
    guard getuid() != 0 else { return }
    print("Changing fan speed needs root. Run:\n  sudo \(CommandLine.arguments[0]) \(cmd)")
    exit(1)
}

func macsFanControlRunning() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    p.arguments = ["-x", "Macs Fan Control"]
    p.standardOutput = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    return p.terminationStatus == 0
}

/// `sudo hawk set <rpm|min|max> [--fan N] [--for seconds]`
/// Holds a speed for a limited time, then always hands the fans back to macOS.
func setFans(_ args: [String]) {
    var rest = args, fanIndex: Int?, seconds = 120.0
    if let i = rest.firstIndex(of: "--fan"), i + 1 < rest.count, let v = Int(rest[i + 1]) { fanIndex = v; rest.removeSubrange(i...i + 1) }
    if let i = rest.firstIndex(of: "--for"), i + 1 < rest.count, let v = Double(rest[i + 1]) { seconds = v; rest.removeSubrange(i...i + 1) }
    seconds = min(max(seconds, 5), 3600)
    guard let value = rest.first else { print("usage: sudo hawk set <rpm|min|max> [--fan 0|1] [--for seconds]"); exit(1) }
    requireRoot("set " + args.joined(separator: " "))

    guard let smc = SMC() else { print("Cannot open AppleSMC"); exit(1) }
    let fans = smc.fans()
    guard let lo = fans.map(\.min).max(), let hi = fans.map(\.max).min() else { print("No fans found"); exit(1) }
    let rpm: Double
    switch value {
    case "min": rpm = lo
    case "max": rpm = hi
    default:
        guard let v = Double(value) else { print("'\(value)' is not a speed. Use a number, min or max."); exit(1) }
        rpm = v
    }
    if rpm < lo { print(String(format: "Note: %.0f rpm is below the minimum; using %.0f. (Fans can't spin slower — only macOS can switch them off.)", rpm, lo)) }
    if rpm > hi { print(String(format: "Note: %.0f rpm is above the maximum; using %.0f.", rpm, hi)) }
    if macsFanControlRunning() {
        print("Warning: Macs Fan Control is running. Make sure its fans are on Auto, or the two programs will fight.")
    }

    for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] { signal(sig) { _ in stopRequested = 1 } }
    let ctl = FanController(smc: smc)
    let targets: [Int: Double]
    do { targets = try ctl.set(rpm: rpm, fans: fanIndex.map { [$0] }) }
    catch { print("Could not take control: \(error). Fans are on automatic."); exit(1) }

    let desc = targets.keys.sorted().map { String(format: "fan%d → %.0f rpm", $0, targets[$0]!) }.joined(separator: ", ")
    print("Manual: \(desc) for \(Int(seconds)) s. Ctrl-C gives control back to macOS early.")
    print(dim("Safety: returns to automatic at 85 °C, if sensors stop reporting, on Ctrl-C, or when the window closes."))

    let hid = HIDSensors(), end = Date().addingTimeInterval(seconds)
    var reason = "time is up", missingSensors = 0
    loop: while true {
        if stopRequested != 0 { reason = "you stopped it"; break }
        let left = end.timeIntervalSinceNow
        if left <= 0 { break }
        let soc = hid.summary().soc
        missingSensors = soc.isEmpty ? missingSensors + 1 : 0
        if missingSensors >= 3 { reason = "temperature sensors stopped reporting"; break }
        if let t = soc.max(), t >= 85 { reason = String(format: "chip reached %.0f °C", t); break }
        let fixed = ctl.reassert()
        let now = smc.fans().map { String(format: "fan%d %4.0f rpm", $0.index, $0.actual) }.joined(separator: "  ")
        let line = "\r  \(now)  │  SoC \(temp(soc.max()))  │  Mac " + String(format: "%.1f W", smc.number("PSTR") ?? 0)
            + String(format: "  │  %d:%02d left", Int(left) / 60, Int(left) % 60)
            + (fixed.isEmpty ? "" : "  (macOS took it back — re-applied)") + "\u{1B}[K"
        print(line, terminator: ""); fflush(stdout)
        for _ in 0..<5 { if stopRequested != 0 { continue loop }; Thread.sleep(forTimeInterval: 0.2) }
    }
    ctl.restore()
    print("\nFans handed back to macOS (\(reason)).")
    for f in smc.fans() { print("  fan\(f.index): mode \(f.mode) \(f.mode == 1 ? "— still manual! run: sudo hawk auto" : "(automatic)")") }
}

/// `sudo hawk auto` — unconditional reset, in case anything was left in manual mode.
func autoFans() {
    requireRoot("auto")
    guard let smc = SMC() else { print("Cannot open AppleSMC"); exit(1) }
    do { try FanController.resetAll(smc: smc) } catch { print("Reset reported an error: \(error)") }
    for f in smc.fans() { print("  fan\(f.index): mode \(f.mode) \(f.mode == 1 ? "— still manual (a reboot will reset it)" : "(automatic)")") }
}

// MARK: - Entry

var args = Array(CommandLine.arguments.dropFirst())
var interval: Double?
if let i = args.firstIndex(of: "-i"), i + 1 < args.count, let v = Double(args[i + 1]) {
    interval = max(0.1, v); args.removeSubrange(i...i + 1)
}
switch args.first {
case "dump": dump(prefix: args.dropFirst().first)
case "log": log(interval: interval ?? 1)
case "set": setFans(Array(args.dropFirst()))
case "auto": autoFans()
case "watch", nil: watch(interval: interval ?? 0.5)
default: print("""
    usage:
      hawk [watch] [-i seconds]                         live dashboard
      hawk log [-i seconds] > run.csv                   CSV for experiments
      hawk dump [KeyPrefix]                             every SMC key + HID sensor
      sudo hawk set <rpm|min|max> [--fan N] [--for s]   hold a speed (default 120 s, max 3600)
      sudo hawk auto                                    give every fan back to macOS
    """)
}
