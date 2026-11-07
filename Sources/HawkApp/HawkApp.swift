//
//  HawkApp.swift
//  Hawk
//
//  One resizable window, always dark, with a hidden title bar so the content
//  runs edge to edge. Closing it quits: the helper sees the connection drop and
//  gives the fans back to macOS.
//

import AppKit
import HawkKit
import SwiftUI

@main
struct HawkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var monitor = Monitor()
    @State private var storage = StorageModel()

    init() {
        // FAN_VERBOSE=1 mirrors every log message, debug timings included, to stderr.
        if ProcessInfo.processInfo.environment["FAN_VERBOSE"] != nil { Log.echoesToStandardError = true }
    }

    var body: some Scene {
        Window("Hawk", id: "main") {
            RootView()
                .environment(monitor)
                .environment(storage)
                .onAppear { delegate.monitor = monitor }
                .frame(minWidth: 440, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 880)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var monitor: Monitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Log.app.info("Hawk \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") started")
    }

    /// Saves the energy totals before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let monitor else { return .terminateNow }
        Task {
            await monitor.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
