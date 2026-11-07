//
//  HawkApp.swift
//  Hawk
//
//  Two scenes: the window (resizable, always dark, hidden title bar) and the
//  menu bar item. Hawk runs from launch to Quit; closing the window keeps it in
//  the menu bar, where fan control, alerts and energy totals carry on.
//

import AppKit
import HawkKit
import SwiftUI

@main
struct HawkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel()

    init() {
        // HAWK_VERBOSE=1 mirrors every log message, debug timings included, to stderr.
        if ProcessInfo.processInfo.environment["HAWK_VERBOSE"] != nil { Log.echoesToStandardError = true }
    }

    var body: some Scene {
        Window("Hawk", id: "main") {
            RootView()
                .environment(app)
                .environment(app.monitor)
                .environment(app.storage)
                .frame(minWidth: 440, minHeight: 420)
                .onAppear { delegate.monitor = app.monitor }
        }
        .windowStyle(.hiddenTitleBar)
        .windowBackgroundDragBehavior(.enabled)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 880)

        MenuBarExtra {
            MenuPanel()
                .environment(app)
                .environment(app.monitor)
        } label: {
            MenuBarLabel()
                .environment(app)
                .environment(app.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var monitor: Monitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        Log.app.info("Hawk \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?") started")
    }

    /// Closing the window is not quitting: Hawk stays in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Saves the energy totals before quitting.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let monitor else { return .terminateNow }
        Task {
            await monitor.stop()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
