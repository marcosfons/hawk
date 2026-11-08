//
//  AdbStrip.swift
//  Hawk
//
//  The Android tab's header: the adb server's state, its version, warnings about
//  the installation, and Start / Stop / Restart. Stop and Restart drop every adb
//  session on the Mac (scrcpy, Android Studio, terminals), so they ask first.
//

import HawkKit
import SwiftUI

struct AdbStrip: View {
    let status: AdbServer.Status
    let start: () -> Void
    let stop: () -> Void
    let restart: () -> Void

    @State private var confirming: Confirmation?

    private enum Confirmation: Identifiable {
        case stop, restart
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(title).font(Typography.label)
                if let version = status.installation?.chosen?.version {
                    Text("adb \(version.description)").font(Typography.small).foregroundStyle(Palette.secondary)
                        .help(status.installation?.chosen?.path ?? "")
                }
                Spacer(minLength: 8)
                if status.installed {
                    if isStopped {
                        Button("Start adb", action: start)
                    } else {
                        Button("Stop adb") { confirming = .stop }
                    }
                    Button("Restart adb") { confirming = .restart }
                }
            }
            .controlSize(.small)
            .disabled(status.activity != nil)
            ForEach(warnings, id: \.self) { warning in
                Text(warning).font(Typography.small).foregroundStyle(Palette.warn).lineLimit(2)
            }
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog(confirming == .stop ? "Stop the adb server?" : "Restart the adb server?",
                            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            presenting: confirming) { which in
            Button(which == .stop ? "Stop adb" : "Restart adb", role: .destructive) {
                which == .stop ? stop() : restart()
            }
        } message: { which in
            Text(which == .stop
                 ? "This disconnects every adb session on this Mac: scrcpy, Android Studio and terminals. Hawk will not start it again until you do."
                 : "This disconnects every adb session on this Mac: scrcpy, Android Studio and terminals.")
        }
    }

    private var isStopped: Bool {
        if case .stopped = status.state { return true }
        return false
    }

    private var title: String {
        if let activity = status.activity { return activity }
        if status.installation != nil, !status.installed { return "adb not found" }
        switch status.state {
        case .stopped(let byUser): return byUser ? "adb stopped" : "adb not started"
        case .starting: return "Starting adb"
        case .running: return status.startedByOther ? "adb running - started by another app" : "adb running"
        case .unhealthy(let reason): return "adb not answering - \(reason)"
        case .backingOff(_, _, let reason): return "adb restarting - \(reason)"
        case .failing(let reason, _): return "adb failing - \(reason)"
        case .versionMismatch: return "Two adb versions are fighting over the server"
        }
    }

    private var color: Color {
        if status.installation != nil, !status.installed { return Palette.hot }
        switch status.state {
        case .running: return Palette.good
        case .starting, .unhealthy, .backingOff: return Palette.warn
        case .failing, .versionMismatch: return Palette.hot
        case .stopped: return Palette.tertiary
        }
    }

    private var warnings: [String] {
        var out = status.installation?.warnings ?? []
        if case .versionMismatch(let server, let client) = status.state {
            let numbers = server.flatMap { s in client.map { " (server \(s), this adb \($0))" } } ?? ""
            out.insert("Another adb version keeps restarting the server\(numbers). Hawk will not restart it on its own; remove one of the copies.", at: 0)
        }
        if status.installation != nil, !status.installed {
            out.append("Install Android platform-tools (Android Studio's SDK Manager, or brew install android-platform-tools).")
        }
        return out
    }
}
