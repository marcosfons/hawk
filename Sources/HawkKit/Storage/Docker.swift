import Foundation

/// Runs a command and returns its exit status and standard output, or nil if it could
/// not start or ran past `timeout` (then it is terminated).
public func runCommand(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
    let started = DispatchTime.now().uptimeNanoseconds
    let label = ([(executable as NSString).lastPathComponent] + arguments.prefix(3)).joined(separator: " ")
    let process = Process()
    process.executableURL = URL(filePath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch {
        Log.engine.error("Could not start \(label): \(error.localizedDescription)")
        return nil
    }
    let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    killer.cancel()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
    if process.terminationReason == .uncaughtSignal {
        Log.engine.warning(String(format: "%@ was stopped after %.0f ms (timeout %.0f s)", label, ms, timeout))
        return nil
    }
    Log.engine.debug(String(format: "%@: exit %d in %.0f ms", label, process.terminationStatus, ms))
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Docker volumes and who uses them. Docker's own numbers describe the Linux VM's disk:
/// removing a volume frees space inside it, but the host's disk image does not shrink
/// (it only stops growing). The UI says so wherever a volume can be removed.
public struct DockerState: Sendable {
    public struct Container: Sendable {
        public let name: String
        public let running: Bool
        public let lastActive: Date?        // running: now; stopped: when it stopped
        public let volumes: [String]
    }
    public struct Volume: Sendable, Identifiable {
        public let name: String
        public var bytes: Int64?
        public var containers: [String]
        public var runningContainers: [String]
        public var lastActive: Date?
        public var id: String { name }
        public var inUse: Bool { !runningContainers.isEmpty }
    }

    public var running = false
    public var containers: [Container] = []
    public var volumes: [Volume] = []
    public var measuredAt = Date()
    public init() {}
}

public enum Docker {
    public static let executable: String? = ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/usr/bin/docker"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// `withSizes` adds `docker system df -v`, which is slow (seconds): ask for it rarely.
    public static func state(withSizes: Bool) -> DockerState {
        var state = DockerState()
        guard let docker = executable,
              let ids = runCommand(docker, ["ps", "-aq"], timeout: 5), ids.status == 0 else { return state }
        state.running = true
        let idList = ids.output.split(separator: "\n").map(String.init)
        if !idList.isEmpty, let inspect = runCommand(docker, ["inspect"] + idList, timeout: 10),
           let json = try? JSONSerialization.jsonObject(with: Data(inspect.output.utf8)) as? [[String: Any]] {
            state.containers = json.map { c in
                let s = c["State"] as? [String: Any] ?? [:]
                let running = s["Running"] as? Bool ?? false
                let finished = (s["FinishedAt"] as? String).flatMap(StorageScan.parseDate)
                let mounts = (c["Mounts"] as? [[String: Any]] ?? []).filter { $0["Type"] as? String == "volume" }.compactMap { $0["Name"] as? String }
                return .init(name: (c["Name"] as? String ?? "?").trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                             running: running, lastActive: running ? Date() : finished.flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil },
                             volumes: mounts)
            }
        }
        let names = runCommand(docker, ["volume", "ls", "-q"], timeout: 5)?.output.split(separator: "\n").map(String.init) ?? []
        var sizes: [String: Int64] = [:]
        if withSizes, let df = runCommand(docker, ["system", "df", "-v", "--format", "{{json .}}"], timeout: 60),
           let json = try? JSONSerialization.jsonObject(with: Data(df.output.utf8)) as? [String: Any] {
            for v in json["Volumes"] as? [[String: Any]] ?? [] {
                if let n = v["Name"] as? String, let s = v["Size"] as? String { sizes[n] = parseSize(s) }
            }
        }
        state.volumes = names.map { name in
            let users = state.containers.filter { $0.volumes.contains(name) }
            return .init(name: name, bytes: sizes[name], containers: users.map(\.name),
                         runningContainers: users.filter(\.running).map(\.name), lastActive: users.compactMap(\.lastActive).max())
        }
        return state
    }

    /// "1.234GB", "512MB", "0B" -> bytes (Docker uses decimal units).
    public static func parseSize(_ s: String) -> Int64? {
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("KB", 1e3), ("B", 1)]
        for (u, m) in units where s.hasSuffix(u) {
            return Double(s.dropLast(u.count)).map { Int64($0 * m) }
        }
        return nil
    }
}
