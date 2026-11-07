//
//  AppModel.swift
//  Hawk
//
//  The app's spine: the feature list (the tabs, in order), which one is
//  selected, and what is on screen (the window, the menu bar panel). From that
//  it tells each feature when it is visible and tells the Monitor what to
//  sample and whether to publish. Nothing else decides visibility.
//

import AppKit
import HawkKit
import Observation
import ServiceManagement

@Observable
final class AppModel {
    let monitor: Monitor
    let storage: StorageModel
    let features: [any Feature]

    var selectedID: String {
        didSet {
            defaults.set(selectedID, forKey: "feature")
            updateVisibility()
        }
    }
    /// The chip temperature next to the menu bar icon.
    var menuShowsTemperature: Bool {
        didSet { defaults.set(menuShowsTemperature, forKey: "menuShowsTemperature") }
    }
    private(set) var windowOpen = false

    @ObservationIgnored private var windowVisible = true
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private let defaults = UserDefaults.standard

    init() {
        let monitor = Monitor()
        let storage = StorageModel()
        self.monitor = monitor
        self.storage = storage
        // The tabs, in order. A new feature is one line here.
        features = [
            OverviewFeature(),
            ProcessesFeature(kind: .cpu),
            ProcessesFeature(kind: .memory),
            EnergyFeature(),
            NetworkFeature(),
            StorageFeature(model: storage),
            AndroidFeature(),
            SecurityFeature(monitor: monitor),
        ]
        selectedID = defaults.string(forKey: "feature") ?? "overview"
        menuShowsTemperature = defaults.object(forKey: "menuShowsTemperature") as? Bool ?? true
        NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }
        monitor.start()
        updateVisibility()
    }

    var selected: any Feature { features.first { $0.id == selectedID } ?? features[0] }

    func windowAppeared() {
        windowOpen = true
        windowVisible = true
        Log.app.info("Window opened on \(selectedID)")
        updateVisibility()
    }

    /// The window was closed: its views are gone, Hawk carries on in the menu bar.
    func windowDisappeared() {
        windowOpen = false
        Log.app.info("Window closed; running in the menu bar")
        updateVisibility()
    }

    func menuPanel(open: Bool) {
        menuOpen = open
        updateVisibility()
    }

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                Log.app.info("Open at login \(newValue ? "on" : "off")")
            } catch {
                Log.app.error("Could not change open at login: \(error.localizedDescription)")
            }
        }
    }

    private func occlusionChanged() {
        let visible = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible && $0.occlusionState.contains(.visible) }
        guard visible != windowVisible else { return }
        windowVisible = visible
        updateVisibility()
    }

    private func updateVisibility() {
        let shown = windowOpen && windowVisible
        let current = selected
        for feature in features { feature.setVisible(shown && feature.id == current.id) }
        monitor.needs = shown ? current.needs : []
        monitor.publishing = shown || menuOpen
    }
}
