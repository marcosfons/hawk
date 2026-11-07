//
//  DataTable.swift
//  Hawk
//
//  A sortable table for lists that change every couple of seconds (processes,
//  energy, network), built on NSTableView. SwiftUI's Table re-diffs and rebuilds
//  row views on every update, which cost 5-15% CPU here; this one re-sorts and
//  rewrites the text of the cells already on screen, so an update is a few dozen
//  string changes. Updates wait while the user scrolls. Selection (by row id)
//  and scroll position survive updates.
//

import AppKit
import HawkKit
import SwiftUI

/// One column: how to show a row's value, and how to order rows by it.
struct Column<Row> {
    let id: String
    let title: String
    let width: CGFloat
    var flexible = false
    var numeric = true
    let text: (Row) -> String
    var color: (Row) -> NSColor? = { _ in nil }
    var icon: ((Row) -> NSImage?)?
    var tooltip: ((Row) -> String?)?
    /// Ascending order.
    let less: (Row, Row) -> Bool
}

/// A context-menu entry for the selected rows; `nil` in a list is a separator.
struct ContextAction {
    let title: String
    var enabled = true
    /// When set, a confirmation sheet (title, message, destructive button) comes first.
    var confirm: (title: String, message: String, button: String)?
    let run: () -> Void
}

struct DataTable<Row: Identifiable>: NSViewRepresentable where Row.ID: Hashable {
    let columns: [Column<Row>]
    let rows: [Row]
    let sortKey: String
    var menu: (([Row]) -> [ContextAction?])?

    func makeCoordinator() -> TableCoordinator {
        TableCoordinator(model: RowsModel(columns: columns, sortKey: sortKey, menu: menu))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .inset
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .clear
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.rowHeight = 22
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        for c in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.id))
            column.title = c.title
            column.width = c.width
            column.minWidth = c.flexible ? 160 : c.width * 0.8
            column.resizingMask = c.flexible ? [.autoresizingMask, .userResizingMask] : .userResizingMask
            column.headerCell.alignment = c.numeric ? .right : .left
            // Big-first for figures, A-to-Z for text.
            column.sortDescriptorPrototype = NSSortDescriptor(key: c.id, ascending: !c.numeric)
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: sortKey, ascending: !(columns.first { $0.id == sortKey }?.numeric ?? true))]
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        if menu != nil {
            let m = NSMenu()
            m.delegate = context.coordinator
            table.menu = m
        }
        context.coordinator.table = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let center = NotificationCenter.default
        center.addObserver(context.coordinator, selector: #selector(TableCoordinator.scrollStarted),
                           name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        center.addObserver(context.coordinator, selector: #selector(TableCoordinator.scrollEnded),
                           name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (context.coordinator.model as? RowsModel<Row>)?.menu = menu
        context.coordinator.update { ($0 as? RowsModel<Row>)?.all = rows }
    }

    /// The table fills whatever it is offered. Without this SwiftUI asks AppKit for the
    /// scroll view's fitting size on every update, which runs Auto Layout over every cell.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 600, height: 400))
    }
}

/// The type-erased side of a table's data, so the AppKit coordinator need not be generic.
protocol TableModel: AnyObject {
    var count: Int { get }
    func sort(key: String, ascending: Bool)
    func resort()
    func configure(_ cell: DataCell, column: String, row: Int)
    func ids(at rows: IndexSet) -> Set<AnyHashable>
    func rows(with ids: Set<AnyHashable>) -> IndexSet
    func actions(for rows: IndexSet) -> [ContextAction?]
    var hasIcons: (String) -> Bool { get }
    var isNumeric: (String) -> Bool { get }
}

final class RowsModel<Row: Identifiable>: TableModel where Row.ID: Hashable {
    private let columns: [String: Column<Row>]
    var menu: (([Row]) -> [ContextAction?])?
    var all: [Row] = []
    private var sorted: [Row] = []
    private var sortKey: String
    private var ascending = false

    init(columns: [Column<Row>], sortKey: String, menu: (([Row]) -> [ContextAction?])?) {
        self.columns = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0) })
        self.sortKey = sortKey
        self.ascending = !(self.columns[sortKey]?.numeric ?? true)
        self.menu = menu
    }

    var count: Int { sorted.count }
    var hasIcons: (String) -> Bool { { [columns] in columns[$0]?.icon != nil } }
    var isNumeric: (String) -> Bool { { [columns] in columns[$0]?.numeric ?? true } }

    func sort(key: String, ascending: Bool) {
        sortKey = key
        self.ascending = ascending
    }

    func resort() {
        guard let column = columns[sortKey] else { sorted = all; return }
        // The id's position in the incoming list breaks ties, so equal rows never swap places.
        let ascending = ascending
        sorted = all.enumerated().sorted { a, b in
            if column.less(a.element, b.element) { return ascending }
            if column.less(b.element, a.element) { return !ascending }
            return a.offset < b.offset
        }.map(\.element)
    }

    func configure(_ cell: DataCell, column: String, row: Int) {
        guard let c = columns[column], row < sorted.count else { return }
        let r = sorted[row]
        cell.configure(text: c.text(r), color: c.color(r) ?? .labelColor, icon: c.icon?(r), tooltip: c.tooltip?(r))
    }

    func ids(at rows: IndexSet) -> Set<AnyHashable> {
        Set(rows.compactMap { $0 < sorted.count ? AnyHashable(sorted[$0].id) : nil })
    }

    func rows(with ids: Set<AnyHashable>) -> IndexSet {
        IndexSet(sorted.indices.filter { ids.contains(AnyHashable(sorted[$0].id)) })
    }

    func actions(for rows: IndexSet) -> [ContextAction?] {
        menu?(rows.compactMap { $0 < sorted.count ? sorted[$0] : nil }) ?? []
    }
}

final class TableCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    weak var table: NSTableView?
    let model: TableModel
    private var scrolling = false
    private var pending = false
    private var actions: [ContextAction] = []

    init(model: TableModel) { self.model = model }

    func update(_ change: (TableModel) -> Void) {
        change(model)
        if scrolling { pending = true } else { reload() }
    }

    @objc func scrollStarted() { scrolling = true }

    @objc func scrollEnded() {
        scrolling = false
        if pending { pending = false; reload() }
    }

    private func reload() {
        guard let table else { return }
        let started = DispatchTime.now().uptimeNanoseconds
        let selected = model.ids(at: table.selectedRowIndexes)
        let before = model.count
        model.resort()
        if model.count != before { table.noteNumberOfRowsChanged() }
        let visible = table.rows(in: table.visibleRect)
        for row in visible.location..<min(visible.location + visible.length, model.count) {
            for (index, column) in table.tableColumns.enumerated() {
                if let cell = table.view(atColumn: index, row: row, makeIfNecessary: false) as? DataCell {
                    model.configure(cell, column: column.identifier.rawValue, row: row)
                }
            }
        }
        let keep = model.rows(with: selected)
        if keep != table.selectedRowIndexes { table.selectRowIndexes(keep, byExtendingSelection: false) }
        // A change in row count makes AppKit lay rows out again, so it gets a looser limit
        // than a steady update, which should fit in one frame.
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        let limit: Double = model.count != before ? 50 : 16
        if ms > limit {
            Log.app.warning(String(format: "Slow: table update of %d rows took %.0f ms (limit %.0f ms)", model.count, ms, limit))
        } else {
            Log.app.debug(String(format: "Table update of %d rows: %.1f ms", model.count, ms))
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { model.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
        model.sort(key: key, ascending: d.ascending)
        reload()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? DataCell
            ?? DataCell(identifier: id, withIcon: model.hasIcons(id.rawValue), numeric: model.isNumeric(id.rawValue))
        model.configure(cell, column: id.rawValue, row: row)
        return cell
    }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        actions = []
        guard let table, table.clickedRow >= 0 else { return }
        let rows = table.selectedRowIndexes.contains(table.clickedRow) ? table.selectedRowIndexes : IndexSet(integer: table.clickedRow)
        for action in model.actions(for: rows) {
            guard let action else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: action.title, action: action.enabled ? #selector(chosen(_:)) : nil, keyEquivalent: "")
            item.target = self
            item.tag = actions.count
            actions.append(action)
            menu.addItem(item)
        }
    }

    @objc private func chosen(_ item: NSMenuItem) {
        guard item.tag < actions.count else { return }
        let action = actions[item.tag]
        guard let confirm = action.confirm, let window = table?.window else { action.run(); return }
        let alert = NSAlert()
        alert.messageText = confirm.title
        alert.informativeText = confirm.message
        alert.addButton(withTitle: confirm.button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { action.run() }
        }
    }
}

/// One table cell: an optional icon and a single line of text, laid out by hand
/// (no constraints), since hundreds of these are configured every update.
final class DataCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let iconView: NSImageView?
    /// One line of the label's font, worked out once instead of measuring on every layout.
    private let lineHeight: CGFloat

    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool, numeric: Bool) {
        iconView = withIcon ? NSImageView() : nil
        let font: NSFont = numeric ? .monospacedDigitSystemFont(ofSize: 11, weight: .medium) : .systemFont(ofSize: 12, weight: .medium)
        lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = font
        label.alignment = numeric ? .right : .left
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        if let iconView {
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.contentTintColor = .tertiaryLabelColor
            addSubview(iconView)
            imageView = iconView
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        var x: CGFloat = 2
        if let iconView {
            iconView.frame = CGRect(x: x, y: (bounds.height - 16) / 2, width: 16, height: 16)
            x += 22
        }
        label.frame = CGRect(x: x, y: (bounds.height - lineHeight) / 2, width: max(bounds.width - x - 2, 0), height: lineHeight)
    }

    func configure(text: String, color: NSColor, icon: NSImage?, tooltip: String?) {
        if label.stringValue != text { label.stringValue = text }
        if label.textColor != color { label.textColor = color }
        if let icon, iconView?.image !== icon { iconView?.image = icon }
        if toolTip != tooltip { toolTip = tooltip }
    }
}

/// App icons by bundle, looked up once: a process inside an .app shows that app's icon.
/// Kept as a 32 x 32 pixel bitmap: the icon NSWorkspace returns carries every size up to
/// 1024 pixels, and caching those cost hundreds of megabytes.
final class IconCache {
    static let shared = IconCache()
    private var icons: [String: NSImage] = [:]
    static let terminal = NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)
    static let daemon = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)

    func icon(forExecutable path: String?) -> NSImage? {
        guard let path, let r = path.range(of: ".app/", options: .backwards) else { return nil }
        let bundle = String(path[..<r.lowerBound]) + ".app"
        if let icon = icons[bundle] { return icon }
        let icon = Self.small(NSWorkspace.shared.icon(forFile: bundle))
        icons[bundle] = icon
        return icon
    }

    private static func small(_ icon: NSImage) -> NSImage {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return icon }
        rep.size = NSSize(width: 16, height: 16)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.addRepresentation(rep)
        return image
    }
}

extension View {
    /// The card look shared by the full-height tables.
    func tableCard() -> some View {
        background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous).fill(Palette.card))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}
