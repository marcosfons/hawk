//
//  Diagnostics.swift
//  Hawk
//
//  Notifications for alerts, and a watchdog that logs when the main thread
//  stalls (what a user feels as a frozen or jumpy window).
//

import HawkKit
import Foundation
import UserNotifications

/// Posts alerts as macOS notifications, asking for permission the first time.
final class Notifier {
    private var authorized: Bool?

    func post(_ alert: FanAlert) {
        Task {
            let center = UNUserNotificationCenter.current()
            if authorized == nil {
                do { authorized = try await center.requestAuthorization(options: [.alert, .sound]) }
                catch {
                    Log.app.warning("Notification permission request failed: \(error.localizedDescription)")
                    authorized = false
                }
                Log.app.info("Notifications \(authorized == true ? "allowed" : "not allowed")")
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            do { try await center.add(UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)) }
            catch { Log.app.warning("Could not post a notification: \(error.localizedDescription)") }
        }
    }
}

/// Every 2 s, measures how long the main thread takes to run a trivial block and logs
/// a warning above 250 ms. Costs one main-queue hop per check.
nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()
    private let queue = DispatchQueue(label: "com.marcos.Hawk.watchdog", qos: .utility)
    private var timer: DispatchSourceTimer?

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(200))
            t.setEventHandler {
                let sent = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    let ms = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                    if ms > 250 { Log.app.warning(String(format: "Main thread was blocked for %.0f ms", ms)) }
                }
            }
            t.resume()
            timer = t
        }
    }
}
