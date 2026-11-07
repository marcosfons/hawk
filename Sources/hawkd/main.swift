// hawkd - the root helper behind Hawk's fan control and system process figures.
//
// launchd starts it as root (see Support/com.marcos.hawkd.plist). It listens on a Unix
// socket that only admin users can open, accepts one client at a time and does nothing
// but set fan speeds or hand them back. Every way out returns the fans to macOS:
//   - the client disconnects (the app quit or crashed)
//   - the client says nothing for Helper.watchdogSeconds
//   - the SoC reaches Helper.hotLimit (then speed requests are refused for a minute)
//   - launchd stops the helper (SIGTERM)
//   - the helper itself crashed: launchd restarts it, and startup resets every fan.

import Darwin
import HawkKit
import Foundation

guard getuid() == 0 else {
    FileHandle.standardError.write(Data("hawkd must run as root; it is started by launchd (sudo make install-helper)\n".utf8))
    exit(1)
}
guard let smc = SMC() else { Log.helper.error("Cannot open AppleSMC"); exit(1) }

let queue = DispatchQueue(label: "com.marcos.hawkd")
let hid = HIDSensors()
let fans = FanController(smc: smc)
var client: Int32 = -1
var clientSource: DispatchSourceRead?
var buffer = Data()
var lastHeard = Date.distantPast
var lockedUntil = Date.distantPast

// A previous run may have died while holding the fans.
do { try FanController.resetAll(smc: smc) } catch { Log.helper.error("Startup reset failed: \(error)") }

func handBack(_ why: String) {
    guard fans.isEngaged else { return }
    fans.restore()
    Log.helper.info("Fans handed back to macOS: \(why)")
}

func reply(_ r: HelperResponse) {
    guard client >= 0, let line = Helper.encodeLine(r) else { return }
    _ = line.withUnsafeBytes { write(client, $0.baseAddress, line.count) }
}

func handle(_ request: HelperRequest) -> HelperResponse {
    switch request {
    case .hello:
        return HelperResponse(ok: true, manual: fans.isEngaged, message: "hawkd ready")
    case .auto:
        handBack("client asked")
        return HelperResponse(ok: true, manual: false)
    case .processes(let skippingUID):
        return HelperResponse(ok: true, manual: fans.isEngaged, processes: readAllCounters(skippingUID: skippingUID))
    case .set(let rpm):
        if Date() < lockedUntil {
            return HelperResponse(ok: false, manual: false, message: "Too hot - macOS keeps control for a minute")
        }
        do {
            let wasEngaged = fans.isEngaged
            try fans.set(rpm: rpm)
            if !wasEngaged { Log.helper.info("Manual control at \(Int(rpm)) rpm") }
            return HelperResponse(ok: true, manual: true)
        } catch {
            Log.helper.error("Could not set \(Int(rpm)) rpm: \(error)")
            return HelperResponse(ok: false, manual: false, message: "\(error)")
        }
    }
}

func dropClient(_ why: String) {
    clientSource?.cancel()
    clientSource = nil
    if client >= 0 { close(client) }
    client = -1
    buffer = Data()
    handBack(why)
}

func readClient() {
    var chunk = [UInt8](repeating: 0, count: 1024)
    let n = read(client, &chunk, chunk.count)
    if n == 0 || (n < 0 && errno != EAGAIN) { dropClient("client disconnected"); return }
    guard n > 0 else { return }
    buffer.append(contentsOf: chunk[0..<n])
    lastHeard = Date()
    while let i = buffer.firstIndex(of: 0x0A) {
        let line = Data(buffer[buffer.startIndex..<i])
        buffer.removeSubrange(buffer.startIndex...i)
        guard let request = try? JSONDecoder().decode(HelperRequest.self, from: line) else {
            reply(HelperResponse(ok: false, manual: fans.isEngaged, message: "unknown request"))
            continue
        }
        reply(Log.helper.timed("request \(request.kind)", warnAbove: 200) { handle(request) })
    }
    if buffer.count > Helper.maxLine { dropClient("request too long") }
}

func acceptClient(_ listener: Int32) {
    let c = accept(listener, nil, nil)
    guard c >= 0 else { return }
    var on: Int32 = 1
    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    if client >= 0 {
        if let line = Helper.encodeLine(HelperResponse(ok: false, manual: false, message: "another client is in control")) {
            _ = line.withUnsafeBytes { write(c, $0.baseAddress, line.count) }
        }
        close(c)
        return
    }
    _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) | O_NONBLOCK)
    client = c
    lastHeard = Date()
    let source = DispatchSource.makeReadSource(fileDescriptor: c, queue: queue)
    source.setEventHandler(handler: readClient)
    source.resume()
    clientSource = source
    Log.helper.info("Client connected")
}

// MARK: - Socket

unlink(Helper.socketPath)
let listener = socket(AF_UNIX, SOCK_STREAM, 0)
var address = Helper.address(Helper.socketPath)
let bound = withUnsafePointer(to: &address) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard listener >= 0, bound == 0 else { Log.helper.error("Cannot bind \(Helper.socketPath): \(String(cString: strerror(errno)))"); exit(1) }
// Admin users only: the same people who could run `sudo fan set` anyway.
chown(Helper.socketPath, 0, 80)          // root:admin
chmod(Helper.socketPath, 0o660)
listen(listener, 4)
_ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

let acceptSource = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
acceptSource.setEventHandler { acceptClient(listener) }
acceptSource.resume()

// MARK: - Watchdog

let watchdog = DispatchSource.makeTimerSource(queue: queue)
watchdog.schedule(deadline: .now() + 1, repeating: 1)
watchdog.setEventHandler {
    guard fans.isEngaged else { return }
    if Date().timeIntervalSince(lastHeard) > Helper.watchdogSeconds {
        handBack("client went quiet for \(Int(Helper.watchdogSeconds)) s")
        return
    }
    if let t = hid.summary().soc.max(), t >= Helper.hotLimit {
        lockedUntil = Date().addingTimeInterval(60)
        handBack(String(format: "SoC reached %.0f °C", t))
        return
    }
    fans.reassert()
}
watchdog.resume()

// MARK: - Shutdown

var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let s = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    s.setEventHandler {
        handBack("helper stopping")
        unlink(Helper.socketPath)
        exit(0)
    }
    s.resume()
    signalSources.append(s)
}

Log.helper.info("hawkd listening on \(Helper.socketPath)")
dispatchMain()
