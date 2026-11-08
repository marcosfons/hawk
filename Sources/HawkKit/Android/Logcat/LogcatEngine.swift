import Foundation

/// One device's logcat: the stream, parsed and classified off the main actor, kept in
/// a ring of the last `capacity` lines, filtered as batches arrive, and published at
/// most four times a second as deltas (requirements 4.1, 4.5, 4.6).
///
/// It runs only while started: the page opens it, closing the page (or the window, or
/// the device going away) stops it, and with it the logcat process on the phone.
public actor LogcatEngine {
    /// What the interface applies: replace everything (`reset`), or drop `dropped`
    /// lines from the front and append `appended`.
    public struct Update: Sendable {
        public var reset = false
        public var lines: [LogEntry] = []
        public var dropped = 0
        /// Lines held in the ring, filtered or not.
        public var total = 0
        /// The stream ended, with why (nil while it runs).
        public var ended: String?
    }

    public nonisolated let updates: AsyncStream<Update>
    private let continuation: AsyncStream<Update>.Continuation

    public let capacity: Int
    private var ring: [LogEntry] = []
    private var shown: [LogEntry] = []
    private var parser = LogParser()
    private var classifier = LogClassifier()
    private var filter = LogFilter().compiled()
    private var context = LogFilter.Context()
    private var partial = Data()
    private var pending: [LogEntry] = []
    private var pendingDropped = 0
    private var task: Task<Void, Never>?
    private var flusher: Task<Void, Never>?
    public private(set) var running = false
    public private(set) var paused = false
    /// Tags seen, for the filter bar's autocomplete (capped).
    public private(set) var tags: Set<String> = []

    public static let command = ["shell", "logcat", "-v", "threadtime", "-v", "uid", "-b", "main,system,crash"]
    static let interval: Duration = .milliseconds(250)

    public init(capacity: Int = 50_000) {
        self.capacity = capacity
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    /// Starts streaming. The first read is the phone's existing buffer, then live lines.
    public func start(_ session: any DeviceSession) {
        guard task == nil else { return }
        running = true
        let stream = session.stream(Self.command)
        task = Task(priority: .utility) { [weak self] in
            var reason = "Logcat ended"
            do {
                for try await chunk in stream { await self?.received(chunk) }
            } catch {
                reason = (error as? AdbError)?.summary ?? error.localizedDescription
            }
            await self?.ended(reason)
        }
        flusher = Task(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.interval, tolerance: .milliseconds(50))
                await self?.flush()
            }
        }
        Log.app.info("Logcat started")
    }

    /// Stops the stream (and the phone's logcat with it). The ring is kept.
    public func stop() {
        guard task != nil else { return }
        task?.cancel()
        flusher?.cancel()
        task = nil
        flusher = nil
        running = false
        partial = Data()
        Log.app.info("Logcat stopped")
    }

    /// Paused: lines are still read and kept, but the view is not updated.
    public func setPaused(_ on: Bool) {
        paused = on
        if !on { publishAll() }
    }

    public func setFilter(_ f: LogFilter) {
        filter = f.compiled()
        publishAll()
    }

    public func setContext(_ c: LogFilter.Context) {
        var c = c
        c.pidProcess = context.pidProcess
        context = c
        publishAll()
    }

    public func clear() {
        ring = []
        shown = []
        pending = []
        pendingDropped = 0
        publishAll()
    }

    /// Everything shown now, for export.
    public func visible() -> [LogEntry] { shown }

    /// Lines in the ring around an entry (for "show lines around this one").
    public func around(_ id: Int, count: Int = 50) -> [LogEntry] {
        guard let i = ring.firstIndex(where: { $0.id == id }) else { return [] }
        return Array(ring[max(0, i - count)..<min(ring.count, i + count + 1)])
    }

    // MARK: -

    private func received(_ chunk: Data) {
        partial.append(chunk)
        guard let lastNewline = partial.lastIndex(of: 0x0A) else {
            // A line longer than this is garbage; drop it rather than grow.
            if partial.count > 64 * 1024 { partial = Data() }
            return
        }
        let complete = partial[partial.startIndex...lastNewline]
        partial = Data(partial[partial.index(after: lastNewline)...])
        let text = String(decoding: complete, as: UTF8.self)
        context.now = Date().timeIntervalSince1970
        var added: [LogEntry] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
            guard var e = parser.parse(trimmed) else { continue }
            classifier.classify(&e)
            if let start = LogClassifier.processStart(e) {
                context.pidProcess[start.pid] = start.process
                if context.pidProcess.count > 4096 { context.pidProcess.removeAll() }
            }
            if tags.count < 2000 { tags.insert(e.tag) }
            added.append(e)
        }
        ring.append(contentsOf: added)
        if ring.count > capacity {
            let over = ring.count - capacity
            let firstKept = ring[over].id
            ring.removeFirst(over)
            // Shown lines older than the ring go too; the view only drops the ones it
            // already has (pending ones were never sent).
            let gone = shown.prefix { $0.id < firstKept }.count
            let pendingGone = pending.prefix { $0.id < firstKept }.count
            shown.removeFirst(gone)
            pending.removeFirst(pendingGone)
            pendingDropped += gone - pendingGone
        }
        let matching = added.filter { filter.matches($0, context) && $0.id >= (ring.first?.id ?? 0) }
        shown.append(contentsOf: matching)
        pending.append(contentsOf: matching)
    }

    private func flush() {
        guard !paused, !pending.isEmpty || pendingDropped > 0 else { return }
        continuation.yield(Update(reset: false, lines: pending, dropped: pendingDropped, total: ring.count))
        pending = []
        pendingDropped = 0
    }

    private func publishAll() {
        context.now = Date().timeIntervalSince1970
        shown = ring.filter { filter.matches($0, context) }
        pending = []
        pendingDropped = 0
        guard !paused else { return }
        continuation.yield(Update(reset: true, lines: shown, total: ring.count))
    }

    private func ended(_ reason: String) {
        flush()
        task = nil
        flusher?.cancel()
        flusher = nil
        running = false
        continuation.yield(Update(total: ring.count, ended: reason))
        Log.app.info("Logcat ended: \(reason)")
    }
}
