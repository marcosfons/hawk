import Foundation

/// Every action that changes a device, appended to its folder's `actions.md`: time,
/// device nickname, action, target, result. Only these typed fields are written, so
/// secrets and command output cannot end up in it.
public enum ActionLog {
    public static let fileName = "actions.md"

    public enum Result: Sendable, Equatable {
        case done
        case failed(String)
        case blocked(String)

        var text: String {
            switch self {
            case .done: "done"
            case .failed(let why): "failed: \(why)"
            case .blocked(let why): "blocked: \(why)"
            }
        }
    }

    static let header = "| Time | Device | Action | Target | Result |\n|---|---|---|---|---|\n"

    /// One table row; cells are kept to one line and cannot break the table.
    public static func row(date: Date, device: String, action: AndroidAction, result: Result) -> String {
        let time = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).dateTimeSeparator(.space))
        return "| " + [time, device, action.name, action.target, result.text].map(cell).joined(separator: " | ") + " |\n"
    }

    /// Appends one row to the device's `actions.md`, starting the table if needed.
    public static func append(date: Date = .now, device: String, action: AndroidAction, result: Result,
                              id: DeviceID, store: DeviceStore) async throws {
        let url = try await store.folder(id).appending(path: fileName)
        let line = Data(row(date: date, device: device, action: action, result: result).utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try (Data(header.utf8) + line).write(to: url, options: .atomic)
        }
    }

    static func cell(_ s: String) -> String {
        String(s.replacingOccurrences(of: "|", with: "/").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").prefix(200))
    }
}
