import Foundation

/// What `adb version` says: "Android Debug Bridge version 1.0.41" and
/// "Version 37.0.1-15733141".
public struct AdbVersion: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The host protocol version, "1.0.41". Servers and clients compare its last number.
    public let protocolVersion: String
    /// The platform-tools release, "37.0.1"; empty for builds that do not print one.
    public let release: String
    /// The build after the dash, "15733141"; empty when absent.
    public let build: String

    public init(protocolVersion: String, release: String, build: String = "") {
        self.protocolVersion = protocolVersion
        self.release = release
        self.build = build
    }

    public var description: String { release.isEmpty ? protocolVersion : "\(release) (\(protocolVersion))" }

    /// nil unless the output carries at least the protocol line. Output is capped first:
    /// it comes from whatever binary was found.
    public static func parse(_ output: String) -> AdbVersion? {
        var proto: String?
        var release = "", build = ""
        for raw in output.prefix(4096).split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Android Debug Bridge version ") {
                proto = String(line.dropFirst("Android Debug Bridge version ".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Version ") {
                let v = line.dropFirst("Version ".count).trimmingCharacters(in: .whitespaces)
                if let dash = v.firstIndex(of: "-") {
                    release = String(v[..<dash])
                    build = String(v[v.index(after: dash)...])
                } else {
                    release = v
                }
            }
        }
        guard let proto, !proto.isEmpty, proto.count <= 32, release.count <= 32, build.count <= 64 else { return nil }
        return AdbVersion(protocolVersion: proto, release: release, build: build)
    }
}

/// Where a candidate path came from, in search order.
public enum AdbSource: String, Sendable, Equatable {
    case environment = "ADB"
    case androidHome = "ANDROID_HOME"
    case sdk = "Android SDK"
    case path = "PATH"
    case homebrew = "Homebrew"
    case usrLocal = "/usr/local/bin"
}

/// One real adb binary, with every path that leads to it.
public struct AdbBinary: Sendable, Equatable {
    /// The first path found that leads to it; the one Hawk runs.
    public let path: String
    public let realPath: String
    public let source: AdbSource
    /// Other paths (symlinks, PATH entries) that resolve to the same file.
    public var aliases: [String]
    public let version: AdbVersion
}

/// A path that looks like adb but cannot be run.
public struct AdbBrokenPath: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        /// A symlink whose target is gone (an SDK that moved).
        case dangling(target: String)
        case notExecutable
        /// It exists and runs, but `adb version` did not answer as adb.
        case noVersion
    }
    public let path: String
    public let reason: Reason
}

/// Every adb on this Mac, the one Hawk uses, and what is wrong with the rest.
public struct AdbInstallation: Sendable, Equatable {
    /// The adb Hawk runs; nil when none was found.
    public var chosen: AdbBinary?
    /// Other real copies (different files), whatever their version.
    public var others: [AdbBinary]
    public var broken: [AdbBrokenPath]

    /// Two copies with different versions kill each other's server on every call.
    public var hasVersionConflict: Bool {
        guard let chosen else { return false }
        return others.contains { $0.version != chosen.version }
    }

    /// Short warnings for the Android header and the connection doctor.
    public var warnings: [String] {
        var out: [String] = []
        if hasVersionConflict, let chosen {
            let list = ([chosen] + others).map { "\($0.path) \($0.version)" }.joined(separator: ", ")
            out.append("Two adb versions installed: they will keep restarting each other's server (\(list))")
        }
        for b in broken {
            switch b.reason {
            case .dangling(let target): out.append("\(b.path) points to \(target), which no longer exists")
            case .notExecutable: out.append("\(b.path) is not executable")
            case .noVersion: out.append("\(b.path) did not answer adb version")
            }
        }
        return out
    }
}

/// What the locator needs from the file system and from running a binary: a seam so
/// the search is tested without touching this Mac.
public protocol AdbProbe: Sendable {
    func inspect(_ path: String) -> AdbPathState
    /// `adb version`'s output, or nil if it did not run or timed out.
    func versionOutput(of path: String) -> String?
}

public enum AdbPathState: Sendable, Equatable {
    case missing
    case dangling(target: String)
    case notExecutable
    case executable(realPath: String, modified: Date)
}

/// Finds adb: `ADB`, `$ANDROID_HOME/platform-tools`, the SDK's default folder, every
/// `adb` in `PATH`, then Homebrew and /usr/local. Symlinks are resolved and copies
/// grouped by real path; each one's version is read once and cached by path and
/// modification date. Hawk always runs the chosen path, never whatever `PATH` gives.
public struct AdbLocator: Sendable {
    public struct Environment: Sendable {
        public var variables: [String: String]
        public var home: String
        public init(variables: [String: String], home: String) {
            self.variables = variables
            self.home = home
        }
        public static var current: Environment {
            Environment(variables: ProcessInfo.processInfo.environment, home: NSHomeDirectory())
        }
    }

    private struct CacheKey: Hashable { let realPath: String; let modified: Date }
    private var versions: [CacheKey: AdbVersion?] = [:]
    private let probe: any AdbProbe

    public init(probe: any AdbProbe = FileAdbProbe()) {
        self.probe = probe
    }

    /// Candidate paths in search order, each path once.
    public static func candidates(in env: Environment) -> [(path: String, source: AdbSource)] {
        var out: [(String, AdbSource)] = []
        var seen = Set<String>()
        func add(_ path: String, _ source: AdbSource) {
            let p = expand(path, home: env.home)
            guard p.hasPrefix("/"), seen.insert(p).inserted else { return }
            out.append((p, source))
        }
        if let adb = env.variables["ADB"], !adb.isEmpty { add(adb, .environment) }
        if let sdk = env.variables["ANDROID_HOME"], !sdk.isEmpty { add(sdk + "/platform-tools/adb", .androidHome) }
        add("~/Library/Android/sdk/platform-tools/adb", .sdk)
        for dir in (env.variables["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            add(String(dir) + "/adb", .path)
        }
        add("/opt/homebrew/bin/adb", .homebrew)
        add("/usr/local/bin/adb", .usrLocal)
        return out
    }

    public mutating func locate(in env: Environment = .current) -> AdbInstallation {
        var binaries: [AdbBinary] = []
        var broken: [AdbBrokenPath] = []
        for (path, source) in Self.candidates(in: env) {
            switch probe.inspect(path) {
            case .missing:
                continue
            case .dangling(let target):
                broken.append(AdbBrokenPath(path: path, reason: .dangling(target: target)))
            case .notExecutable:
                broken.append(AdbBrokenPath(path: path, reason: .notExecutable))
            case .executable(let realPath, let modified):
                if let i = binaries.firstIndex(where: { $0.realPath == realPath }) {
                    binaries[i].aliases.append(path)
                    continue
                }
                if broken.contains(where: { $0.path == realPath }) { continue }
                guard let version = version(of: realPath, modified: modified) else {
                    broken.append(AdbBrokenPath(path: realPath, reason: .noVersion))
                    continue
                }
                binaries.append(AdbBinary(path: path, realPath: realPath, source: source, aliases: [], version: version))
            }
        }
        return AdbInstallation(chosen: binaries.first, others: Array(binaries.dropFirst()), broken: broken)
    }

    private mutating func version(of realPath: String, modified: Date) -> AdbVersion? {
        let key = CacheKey(realPath: realPath, modified: modified)
        if let cached = versions[key] { return cached }
        let parsed = probe.versionOutput(of: realPath).flatMap(AdbVersion.parse)
        versions = versions.filter { $0.key.realPath != realPath }
        versions[key] = parsed
        return parsed
    }

    static func expand(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + path.dropFirst() }
        return path
    }
}

/// The real file system, and `adb version` run with a timeout.
public struct FileAdbProbe: AdbProbe {
    public init() {}

    public func inspect(_ path: String) -> AdbPathState {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        guard let resolved = realpath(path, nil) else {
            if (st.st_mode & S_IFMT) == S_IFLNK {
                let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) ?? "?"
                return .dangling(target: target)
            }
            return .missing
        }
        let real = String(cString: resolved)
        free(resolved)
        var target = stat()
        guard stat(real, &target) == 0, (target.st_mode & S_IFMT) == S_IFREG, access(real, X_OK) == 0 else { return .notExecutable }
        let modified = Date(timeIntervalSince1970: TimeInterval(target.st_mtimespec.tv_sec))
        return .executable(realPath: real, modified: modified)
    }

    public func versionOutput(of path: String) -> String? {
        guard let r = runCommand(path, ["version"], timeout: 5), r.status == 0 else { return nil }
        return r.output
    }
}
