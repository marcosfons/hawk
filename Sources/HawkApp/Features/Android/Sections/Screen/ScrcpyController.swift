//
//  ScrcpyController.swift
//  Hawk
//
//  One device's scrcpy session: start, stop, and relaunch in place when an option
//  changes (scrcpy has no control channel). Its window is found by PID with
//  CGWindowList, which needs no permission; the lookup polls only while a
//  relaunch waits for the new window. scrcpy is told which adb to use (ADB), so
//  it shares Hawk's server, and is stopped when Hawk quits.
//

import AppKit
import CoreGraphics
import HawkKit
import Observation

@Observable
final class ScrcpyController {
    private(set) var running = false
    private(set) var recording: URL?
    private(set) var error: String?
    private(set) var capabilities: ScrcpyCapabilities?
    var options: ScrcpyOptions { didSet { if options != oldValue { saveOptions() } } }

    @ObservationIgnored let device: DeviceID
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var log = ""
    @ObservationIgnored private var texture: (width: Int, height: Int)?
    @ObservationIgnored private var lastWindow: ScrcpyWindow?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var stoppingOnPurpose = false

    init(device: DeviceID) {
        self.device = device
        let key = DeviceStore.folderName(device)
        options = (UserDefaults.standard.data(forKey: "scrcpyOptions.\(key)")).flatMap { try? JSONDecoder().decode(ScrcpyOptions.self, from: $0) } ?? ScrcpyOptions()
        lastWindow = (UserDefaults.standard.data(forKey: "scrcpyWindow.\(key)")).flatMap { try? JSONDecoder().decode(ScrcpyWindow.self, from: $0) }
    }

    var installed: Bool { Scrcpy.locate() != nil }

    /// Reads what the installed scrcpy supports, once.
    func loadCapabilities() async {
        guard capabilities == nil, let path = Scrcpy.locate() else { return }
        let runner = AdbProcess(executable: path)
        async let version = try? runner.run(["--version"], timeout: .seconds(5))
        async let help = try? runner.run(["--help"], timeout: .seconds(5))
        let (v, h) = await (version, help)
        capabilities = ScrcpyCapabilities.parse(version: v?.text ?? "", help: (h?.text ?? "") + (h?.stderr ?? ""))
    }

    func start(serial: String, title: String, adb: String?, record: URL? = nil, recordOnly: Bool = false, keepScreen: Bool = false) {
        guard process == nil, let path = Scrcpy.locate(), let caps = capabilities else { return }
        error = nil
        log = ""
        let args = Scrcpy.arguments(options, serial: serial, title: title, window: recordOnly ? nil : lastWindow, capabilities: caps,
                                    record: record, recordOnly: recordOnly, keepScreenAsIs: keepScreen)
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let adb { env["ADB"] = adb }
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard !data.isEmpty else { h.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in self?.received(text) }
        }
        p.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            Task { @MainActor in self?.exited(status) }
        }
        do {
            try p.run()
            ChildProcesses.shared.track(p.processIdentifier)
            process = p
            running = true
            recording = record
            Log.app.info("scrcpy started")
        } catch {
            self.error = "Could not start scrcpy: \(error.localizedDescription)"
        }
    }

    func stop() async {
        guard let p = process else { return }
        stoppingOnPurpose = true
        rememberWindow()
        p.terminate()
        for _ in 0..<40 where p.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// New options in the same spot: read the window, stop, start again there.
    func relaunch(serial: String, title: String, adb: String?) async {
        guard running, recording == nil else { return }
        await stop()
        for _ in 0..<20 where process != nil { try? await Task.sleep(for: .milliseconds(50)) }
        for attempt in 0..<2 {
            start(serial: serial, title: title, adb: adb, keepScreen: true)
            if await waitForWindow() { return }
            if attempt == 0, process == nil { Log.app.warning("scrcpy exited without a window; trying once more") } else { return }
        }
    }

    // MARK: -

    private func received(_ text: String) {
        if log.count < 64 * 1024 { log += text }
        if let t = Scrcpy.parseLog(text).texture { texture = t }
    }

    private func exited(_ status: Int32) {
        if let p = process { ChildProcesses.shared.untrack(p.processIdentifier) }
        process = nil
        running = false
        recording = nil
        if !stoppingOnPurpose, status != 0 {
            let errors = Scrcpy.parseLog(log).errors
            error = errors.last ?? "scrcpy stopped (status \(status))"
        }
        stoppingOnPurpose = false
        Log.app.info("scrcpy exited (\(status))")
    }

    /// Polls for the window only during a relaunch: 3 s at most.
    private func waitForWindow() async -> Bool {
        for _ in 0..<30 {
            if windowFrame() != nil { return true }
            if process == nil { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return windowFrame() != nil
    }

    private func windowFrame() -> CGRect? {
        guard let pid = process?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int ?? 0) < 25 {
            if let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b as CFDictionary), r.width > 50 {
                return r
            }
        }
        return nil
    }

    private func rememberWindow() {
        guard let frame = windowFrame(), !options.fullscreen else { return }
        let titleBar = options.borderless ? 0 : NSWindow.frameRect(forContentRect: .zero, styleMask: [.titled]).height
        let window = ScrcpyWindow.content(ofFrame: frame, titleBar: titleBar).fitted(to: texture)
        lastWindow = window
        if let data = try? JSONEncoder().encode(window) { defaults.set(data, forKey: "scrcpyWindow.\(DeviceStore.folderName(device))") }
    }

    private func saveOptions() {
        if let data = try? JSONEncoder().encode(options) { defaults.set(data, forKey: "scrcpyOptions.\(DeviceStore.folderName(device))") }
    }
}
