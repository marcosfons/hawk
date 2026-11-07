//
//  ProcessColumns.swift
//  Hawk
//
//  Columns and the context menu for the CPU and Memory tabs' process tables.
//  A figure the app could not read shows as "-".
//

import AppKit
import HawkKit

enum ProcessColumns {
    /// A numeric column that shows "-" for processes whose counters were not readable.
    static func figure(_ id: String, _ title: String, _ width: CGFloat, text: @escaping (ProcessStat) -> String,
                       color: @escaping (ProcessStat) -> NSColor? = { _ in nil },
                       less: @escaping (ProcessStat, ProcessStat) -> Bool) -> Column<ProcessStat> {
        Column(id: id, title: title, width: width, text: { $0.readable ? text($0) : "-" },
               color: { $0.readable ? color($0) : .tertiaryLabelColor }, less: less)
    }

    static let name = Column<ProcessStat>(
        id: "name", title: "Process", width: 260, flexible: true, numeric: false, text: \.name,
        color: { $0.readable ? nil : .secondaryLabelColor },
        icon: { IconCache.shared.icon(forExecutable: $0.path) ?? ($0.isMine ? IconCache.terminal : IconCache.daemon) },
        tooltip: { $0.path ?? $0.name },
        less: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })
    static let threads = figure("threads", "Threads", 58, text: { $0.threads >= 0 ? "\($0.threads)" : "-" }, less: { $0.threads < $1.threads })
    static let pid = Column<ProcessStat>(id: "pid", title: "PID", width: 58, text: { "\($0.pid)" }, less: { $0.pid < $1.pid })
    static let user = Column<ProcessStat>(id: "user", title: "User", width: 90, numeric: false, text: \.user,
                                          color: { _ in .secondaryLabelColor }, less: { $0.user < $1.user })

    static let cpu: [Column<ProcessStat>] = [
        name,
        figure("cpu", "% CPU", 60, text: { String(format: "%.1f", $0.cpu * 100) }, less: { $0.cpu < $1.cpu }),
        figure("power", "Power (W)", 72, text: { Format.processWatts($0.power) }, less: { $0.power < $1.power }),
        figure("cpuTime", "CPU Time", 82, text: { Format.cpuTime($0.cpuTime) }, less: { $0.cpuTime < $1.cpuTime }),
        threads,
        figure("wakeups", "Wake-ups/s", 78, text: { String(format: "%.0f", $0.wakeups) }, less: { $0.wakeups < $1.wakeups }),
        figure("disk", "Disk", 78, text: { $0.disk > 0 ? Format.rate($0.disk) : "0" }, less: { $0.disk < $1.disk }),
        pid, user,
    ]

    static let memory: [Column<ProcessStat>] = [
        name,
        figure("memory", "Memory", 78, text: { Format.bytes(Double($0.memory)) }, less: { $0.memory < $1.memory }),
        figure("growth", "Last minute", 84, text: { Format.signedBytes($0.growth) },
               color: { $0.growth > 10_000_000 ? NSColor(Palette.warn) : $0.growth < 0 ? NSColor(Palette.good) : nil },
               less: { $0.growth < $1.growth }),
        figure("peak", "Peak", 78, text: { Format.bytes(Double($0.peak)) }, less: { $0.peak < $1.peak }),
        figure("resident", "In RAM", 78, text: { Format.bytes(Double($0.resident)) }, less: { $0.resident < $1.resident }),
        threads, pid, user,
    ]

    /// Copy, show in Finder, and quit (own processes only, after a confirmation).
    static func menu(_ chosen: [ProcessStat]) -> [ContextAction?] {
        guard let first = chosen.first else { return [] }
        let mine = chosen.allSatisfy { $0.isMine && $0.pid != getpid() }
        let what = chosen.count == 1 ? first.name : "\(chosen.count) processes"
        var items: [ContextAction?] = [
            ContextAction(title: "Copy Name") { copy(chosen.map(\.name).joined(separator: "\n")) },
            ContextAction(title: "Copy PID") { copy(chosen.map { String($0.pid) }.joined(separator: " ")) },
        ]
        if chosen.count == 1, let path = first.path {
            items.append(ContextAction(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) })
        }
        items.append(nil)
        items.append(ContextAction(title: "Quit…", enabled: mine,
                                   confirm: ("Quit \(what)?", "The processes are asked to quit and may save their work first.", "Quit")) {
            signal(chosen, SIGTERM, verb: "quit")
        })
        items.append(ContextAction(title: "Force Quit…", enabled: mine,
                                   confirm: ("Force quit \(what)?", "Unsaved changes in these processes will be lost.", "Force Quit")) {
            signal(chosen, SIGKILL, verb: "force quit")
        })
        return items
    }

    private static func signal(_ chosen: [ProcessStat], _ sig: Int32, verb: String) {
        for p in chosen {
            if kill(p.pid, sig) == 0 { Log.app.info("Asked \(p.name) (\(p.pid)) to \(verb)") }
            else { Log.app.warning("Could not \(verb) \(p.name) (\(p.pid)): \(String(cString: strerror(errno)))") }
        }
    }

    private static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}
