//
//  LogTable.swift
//  Hawk
//
//  The log list: an NSTableView for up to 50k lines that grows by appending. A
//  new batch reloads only what is visible; while the view is at the bottom it
//  follows the tail, and scrolling up stops following until it is back at the
//  bottom. DataTable re-sorts every row on each update, too slow for a log.
//

import AppKit
import HawkKit
import SwiftUI

struct LogTable: NSViewRepresentable {
    let rows: [LogEntry]
    /// Changes whenever `rows` does, so updates are cheap to detect.
    let version: Int
    let app: (LogEntry) -> (name: String, color: NSColor?)
    let onSelect: (LogEntry?) -> Void
    let menu: (LogEntry) -> [ContextAction?]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = 18
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.allowsMultipleSelection = false
        table.usesAutomaticRowHeights = false
        table.gridStyleMask = []
        for (id, title, width) in [("time", "Time", 92.0), ("level", "", 18.0), ("app", "App", 150.0), ("tag", "Tag", 140.0),
                                   ("pid", "PID", 52.0), ("message", "Message", 600.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            c.minWidth = id == "message" ? 200 : width * 0.6
            c.resizingMask = id == "message" ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            table.addTableColumn(c)
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let menu = NSMenu()
        menu.delegate = context.coordinator
        table.menu = menu
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.app = app
        c.onSelect = onSelect
        c.menuItems = menu
        guard c.version != version, let table = c.table else { return }
        let following = c.isAtBottom(scroll)
        let selectedID = c.rows.indices.contains(table.selectedRow) ? c.rows[table.selectedRow].id : nil
        c.rows = rows
        c.version = version
        table.reloadData()
        if let selectedID, let i = rows.firstIndex(where: { $0.id == selectedID }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        }
        if following, !rows.isEmpty { table.scrollRowToVisible(rows.count - 1) }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var rows: [LogEntry] = []
        var version = -1
        weak var table: NSTableView?
        var app: (LogEntry) -> (name: String, color: NSColor?) = { _ in ("", nil) }
        var onSelect: (LogEntry?) -> Void = { _ in }
        var menuItems: (LogEntry) -> [ContextAction?] = { _ in [] }
        private var actions: [() -> Void] = []
        private let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        private let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        private let timeFormat: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        func isAtBottom(_ scroll: NSScrollView) -> Bool {
            guard let doc = scroll.documentView else { return true }
            return scroll.contentView.bounds.maxY >= doc.bounds.maxY - 40
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
            guard let column, row < rows.count else { return nil }
            let id = column.identifier
            let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                f.font = font
                return f
            }()
            let e = rows[row]
            let levelColor = Self.color(e.effectiveLevel)
            switch id.rawValue {
            case "time":
                field.stringValue = timeFormat.string(from: Date(timeIntervalSince1970: e.time))
                field.textColor = .tertiaryLabelColor
            case "level":
                field.stringValue = e.effectiveLevel.letter
                field.font = bold
                field.textColor = levelColor
            case "app":
                let a = app(e)
                field.stringValue = a.name
                field.textColor = a.color ?? .secondaryLabelColor
            case "tag":
                field.stringValue = e.tag
                field.textColor = .secondaryLabelColor
            case "pid":
                field.stringValue = String(e.pid)
                field.textColor = .tertiaryLabelColor
            default:
                field.stringValue = e.message
                // Only warnings and above colour the message, so normal logs stay calm.
                field.textColor = e.effectiveLevel >= .warn ? levelColor : (e.kind == .stackFrame || e.kind == .dartFrame ? .secondaryLabelColor : Palette.logInfo)
            }
            return field
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = NSTableRowView()
            if row < rows.count, rows[row].effectiveLevel == .fatal || rows[row].kind == .javaCrash || rows[row].kind == .anr {
                view.backgroundColor = Palette.logError.withAlphaComponent(0.12)
            }
            return view
        }

        func tableViewSelectionDidChange(_ n: Notification) {
            guard let table = n.object as? NSTableView else { return }
            onSelect(table.selectedRow >= 0 && table.selectedRow < rows.count ? rows[table.selectedRow] : nil)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            actions = []
            guard let table, table.clickedRow >= 0, table.clickedRow < rows.count else { return }
            for item in menuItems(rows[table.clickedRow]) {
                guard let item else { menu.addItem(.separator()); continue }
                let mi = NSMenuItem(title: item.title, action: #selector(run(_:)), keyEquivalent: "")
                mi.target = self
                mi.tag = actions.count
                mi.isEnabled = item.enabled
                actions.append(item.run)
                menu.addItem(mi)
            }
        }

        @objc private func run(_ item: NSMenuItem) {
            guard item.tag < actions.count else { return }
            actions[item.tag]()
        }

        static func color(_ level: LogLevel) -> NSColor {
            switch level {
            case .verbose: Palette.logVerbose
            case .debug: Palette.logDebug
            case .info: Palette.logInfo
            case .warn: Palette.logWarn
            case .error, .fatal: Palette.logError
            }
        }
    }
}
