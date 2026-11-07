//
//  Feature.swift
//  Hawk
//
//  The unit Hawk grows by. A feature is one tab: a title and symbol, a view,
//  and two optional hooks for work outside the view:
//
//  - `needs`: shared system data (processes, network, energy) the feature wants
//    while it is on screen. The Monitor samples it only while some visible
//    feature needs it.
//  - `setVisible`: told whenever the feature comes on or goes off screen, so it
//    can start or stop its own foreground work (usually through a Refresher).
//
//  Work that must run with no window at all (fan control, alerts, energy
//  totals) belongs to the Monitor's Engine, not to a feature. Adding a tab:
//  write a class conforming to Feature in Features/<Name>/, then list it in
//  AppModel.init. See CLAUDE.md, "Adding a feature".
//

import SwiftUI

/// Shared data a feature can ask the Monitor for while it is visible.
nonisolated enum Need: String, Hashable, Sendable {
    case processes, network, energy
}

protocol Feature: AnyObject {
    /// Stable: saved as the selected tab.
    var id: String { get }
    var title: String { get }
    var symbol: String { get }
    var needs: Set<Need> { get }
    func makeView() -> AnyView
    func setVisible(_ visible: Bool)
}

extension Feature {
    var needs: Set<Need> { [] }
    func setVisible(_ visible: Bool) {}
}

extension EnvironmentValues {
    /// The window's content width, so feature layouts can switch between one and two
    /// columns without measuring themselves.
    @Entry var contentWidth: CGFloat = 1000
}
