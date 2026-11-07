//
//  Refresher.swift
//  Hawk
//
//  Runs a feature's periodic work at the right rate: every `foreground` while
//  the feature is on screen, every `background` (or never) otherwise. Becoming
//  visible runs the work at once, so a tab never opens on stale data.
//
//  The work closure runs on the main actor and should hand anything slow to an
//  actor of its own; it only waits for the result.
//

import HawkKit

final class Refresher {
    private let foreground: Duration
    private let background: Duration?
    private let name: String
    private let work: () async -> Void
    private var task: Task<Void, Never>?

    var visible = false {
        didSet { if visible != oldValue { restart() } }
    }

    init(_ name: String, foreground: Duration, background: Duration?, work: @escaping () async -> Void) {
        self.name = name
        self.foreground = foreground
        self.background = background
        self.work = work
        if background != nil { restart() }
    }

    deinit { task?.cancel() }

    /// Runs the work now, whatever the schedule (a "Check now" button).
    func runNow() {
        restart()
    }

    private func restart() {
        task?.cancel()
        guard let interval = visible ? foreground : background else {
            task = nil
            return
        }
        let work = work, name = name
        task = Task {
            while !Task.isCancelled {
                let started = ContinuousClock.now
                await work()
                Log.app.debug("\(name) refresh: \(started.duration(to: .now))")
                try? await Task.sleep(for: interval)
            }
        }
    }
}
