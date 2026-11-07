//
//  Log.swift
//  HawkKit
//
//  Logging, in two layers:
//
//  - Everything goes to the unified log under the process's subsystem
//    (com.marcos.Hawk for the app, com.marcos.hawkd for the helper), so it shows
//    up in Console.app and in `make log`.
//  - Warnings and errors from the app are also appended to
//    ~/Library/Logs/Hawk/hawk.log, a small file that outlives the unified log's
//    retention. The root helper logs to the unified log only.
//

import Foundation
import OSLog
import Synchronization

public struct Log: Sendable {
    static let subsystem = getuid() == 0 ? Helper.label : (Bundle.main.bundleIdentifier ?? "com.marcos.Hawk")

    public static let app = Log(category: "app")
    public static let engine = Log(category: "engine")
    public static let helper = Log(category: "helper")

    /// Whether messages are mirrored to standard error.
    public static var echoesToStandardError: Bool {
        get { echo.load(ordering: .relaxed) }
        set { echo.store(newValue, ordering: .relaxed) }
    }

    private static let echo = Atomic<Bool>(false)

    /// Whether warnings and errors also go to the problem log file: not for the root
    /// helper (no user Library), and not for test runs, whose made-up alerts would
    /// read as real problems.
    static let keepsProblems: Bool = {
        let name = ProcessInfo.processInfo.processName
        return getuid() != 0 && !name.contains("xctest") && !name.contains("swiftpm-testing")
    }()

    let category: String
    private let logger: Logger

    init(category: String) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category)
    }

    /// Developer detail; kept in memory only, never in the problem log.
    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        echo("debug", message)
    }

    /// Normal events: mode changes, helper connections.
    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        echo("info", message)
    }

    /// Something went wrong but the program carried on.
    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        echo("warning", message)
        if Self.keepsProblems { ProblemLog.shared.append(level: "warning", category: category, message: message) }
    }

    /// An operation failed: a fan write, the helper socket.
    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        echo("error", message)
        if Self.keepsProblems { ProblemLog.shared.append(level: "error", category: category, message: message) }
    }

    private func echo(_ level: String, _ message: String) {
        guard Self.echoesToStandardError else { return }
        FileHandle.standardError.write(Data("[\(category)] \(level): \(message)\n".utf8))
    }
}

/// Appends warnings and errors to a plain-text file, rotating it once it
/// passes `maximumSize` so it never grows without bound.
final class ProblemLog: Sendable {
    static let shared = ProblemLog(fileURL: defaultFileURL)

    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Hawk/hawk.log", directoryHint: .notDirectory)
    }

    let fileURL: URL
    let maximumSize: Int
    private let queue = DispatchQueue(label: "com.marcos.Hawk.problem-log", qos: .utility)

    init(fileURL: URL, maximumSize: Int = 256 * 1024) {
        self.fileURL = fileURL
        self.maximumSize = maximumSize
    }

    /// The previous file, kept after rotation.
    var rotatedFileURL: URL {
        fileURL.deletingPathExtension().appendingPathExtension("old.log")
    }

    func append(level: String, category: String, message: String, date: Date = .now) {
        let line = "\(date.formatted(.iso8601)) [\(category)] \(level): \(message)\n"
        queue.async { self.write(line) }
    }

    /// Blocks until every pending line is on disk.
    func flush() {
        queue.sync {}
    }

    private func write(_ line: String) {
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > maximumSize {
                try? manager.removeItem(at: rotatedFileURL)
                try manager.moveItem(at: fileURL, to: rotatedFileURL)
            }
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Nowhere left to report it but the unified log.
            Logger(subsystem: Log.subsystem, category: "log")
                .fault("Could not write the problem log: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension Log {
    /// Runs `work` and logs how long it took: at debug level normally, as a warning
    /// ("Slow: ...", kept in the problem log) when it took longer than `warnAbove` ms.
    @discardableResult
    public func timed<T>(_ what: String, warnAbove ms: Double, _ work: () throws -> T) rethrows -> T {
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try work()
        let taken = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
        if taken > ms {
            warning(String(format: "Slow: %@ took %.0f ms (limit %.0f ms)", what, taken, ms))
        } else {
            debug(String(format: "%@: %.1f ms", what, taken))
        }
        return result
    }
}
