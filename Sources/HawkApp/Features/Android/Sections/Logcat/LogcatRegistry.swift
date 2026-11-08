//
//  LogcatRegistry.swift
//  Hawk
//
//  One Logcat model per device, living as long as Hawk so Keep running can carry
//  a stream past its page (requirements 4.4). Without Keep running, a stream stops
//  when its page goes away; with it, it stops when switched off, when the device
//  goes, or when Hawk quits (it is never saved: every launch starts with it off).
//

import HawkKit
import Observation

@Observable
final class LogcatRegistry {
    static let shared = LogcatRegistry()
    private var models: [DeviceID: LogcatModel] = [:]

    func model(for id: DeviceID) -> LogcatModel {
        if let m = models[id] { return m }
        let m = LogcatModel()
        models[id] = m
        return m
    }

    /// Devices whose logcat runs with Keep running on: a red chip on the device and
    /// a marker in the menu bar, so it is never forgotten.
    func keptRunning(_ id: DeviceID) -> Bool { models[id].map { $0.keepRunning && $0.running } ?? false }
    var anyKeptRunning: Bool { models.values.contains { $0.keepRunning && $0.running } }
}
