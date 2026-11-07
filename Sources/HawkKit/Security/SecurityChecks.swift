import Foundation
import Security

/// Something worth a look. Not a verdict: most findings have innocent explanations,
/// and the detail says what to check.
public struct Finding: Sendable, Identifiable, Equatable {
    public enum Severity: Int, Sendable, Comparable {
        case info, notice, warning
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public let id: String          // stable, so a finding keeps its row and is not re-alerted
    public let severity: Severity
    public let kind: String        // "Startup item", "Process", "Secret file", "Signature"
    public let title: String
    public let detail: String
    public let path: String?
}

/// A launchd job: something that starts on its own (at login, at boot, on a schedule).
public struct LaunchItem: Sendable, Identifiable, Equatable {
    public let label: String
    public let plist: String
    public let program: String?
    public let scope: String       // "You", "All users", "System daemon"
    public let modified: Date?
    public var id: String { plist }

    public init(label: String, plist: String, program: String?, scope: String, modified: Date?) {
        self.label = label; self.plist = plist; self.program = program; self.scope = scope; self.modified = modified
    }
}

public enum SecurityChecks {
    static let launchDirs: [(String, String)] = [
        ("~/Library/LaunchAgents", "You"), ("/Library/LaunchAgents", "All users"), ("/Library/LaunchDaemons", "System daemon"),
    ]

    /// Every third-party startup item (Apple's own live in /System and are left out).
    public static func launchItems() -> [LaunchItem] {
        launchDirs.flatMap { dir, scope -> [LaunchItem] in
            let folder = StorageRules.expand(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            return names.filter { $0.hasSuffix(".plist") }.map { name in
                let path = folder + "/" + name
                let plist = NSDictionary(contentsOfFile: path)
                let program = plist?["Program"] as? String ?? (plist?["ProgramArguments"] as? [String])?.first
                let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                return LaunchItem(label: plist?["Label"] as? String ?? name, plist: path, program: program, scope: scope, modified: modified)
            }
        }
        .sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// Places programs should not run from: temporary and shared folders, Downloads,
    /// hidden folders.
    public static func unusualLocation(_ path: String) -> String? {
        let p = path.lowercased()
        if p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") || p.hasPrefix("/var/tmp/") || p.hasPrefix("/private/var/tmp/") {
            return "a temporary folder"
        }
        if p.hasPrefix("/users/shared/") { return "the shared folder every user can write to" }
        if p.hasPrefix(NSHomeDirectory().lowercased() + "/downloads/") { return "Downloads" }
        let parts = path.split(separator: "/")
        if let hidden = parts.dropLast().first(where: { $0.hasPrefix(".") && !["local", "cargo", "bun", "deno", "nvm", "rbenv", "pyenv", "asdf", "volta", "rustup", "sdkman"].contains($0.dropFirst()) }) {
            return "a hidden folder (\(hidden))"
        }
        return nil
    }

    /// Cheap checks (a few milliseconds): startup items and where running programs live.
    public static func quick(items: [LaunchItem], processes: [ProcessStat], now: Date = Date()) -> [Finding] {
        var out: [Finding] = []
        for item in items {
            guard let program = item.program else { continue }
            if !program.hasPrefix("/") {
                continue      // a bare command resolved through PATH; nothing to check by path
            }
            if !FileManager.default.fileExists(atPath: program) {
                out.append(Finding(id: "missing:\(item.plist)", severity: .notice, kind: "Startup item", title: "\(item.label) points to a missing program",
                                   detail: "Usually a leftover from an uninstalled app. Remove the plist if you don't recognise it.", path: item.plist))
            } else if let place = unusualLocation(program) {
                out.append(Finding(id: "place:\(item.plist)", severity: .warning, kind: "Startup item", title: "\(item.label) starts a program from \(place)",
                                   detail: "Startup items normally run installed apps. Check what \(program) is.", path: program))
            }
            if let modified = item.modified, now.timeIntervalSince(modified) < 7 * 86400 {
                out.append(Finding(id: "new:\(item.plist)", severity: .info, kind: "Startup item", title: "\(item.label) was added or changed recently",
                                   detail: "Changed \(Format.ago(modified)). Fine if you just installed or updated something.", path: item.plist))
            }
        }
        for p in processes {
            guard let path = p.path else { continue }
            if let place = unusualLocation(path) {
                out.append(Finding(id: "proc:\(path)", severity: .warning, kind: "Process", title: "\(p.name) runs from \(place)",
                                   detail: "PID \(p.pid), user \(p.user). Installed programs don't usually run from there.", path: path))
            } else if !FileManager.default.fileExists(atPath: path) {
                out.append(Finding(id: "gone:\(path)", severity: .notice, kind: "Process", title: "\(p.name) runs from a file that no longer exists",
                                   detail: "PID \(p.pid). Common after an update (restart the app); unusual otherwise.", path: path))
            }
        }
        return out
    }

    /// Files whose access is worth knowing about, with the programs expected to open them.
    static let secrets: [(path: String, what: String, owners: [String])] = [
        ("~/.ssh/id_ed25519", "your SSH key", ["ssh", "ssh-agent", "ssh-add", "git"]),
        ("~/.ssh/id_rsa", "your SSH key", ["ssh", "ssh-agent", "ssh-add", "git"]),
        ("~/Library/Keychains/login.keychain-db", "your login keychain", ["secd", "securityd", "trustd", "SecurityAgent", "accountsd"]),
        ("~/Library/Application Support/Google/Chrome/Default/Cookies", "Chrome's cookies", ["Google Chrome", "Google Chrome Helper"]),
        ("~/Library/Application Support/Google/Chrome/Default/Login Data", "Chrome's saved passwords", ["Google Chrome", "Google Chrome Helper"]),
        ("~/Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies", "Safari's cookies", ["Safari", "com.apple.WebKit.Networking"]),
    ]

    /// Which of this user's processes hold a secret file open right now (lsof on a short
    /// list of files: a fraction of a second). Opened by its own app, a file is fine.
    public static func secretFileAccess() -> [Finding] {
        let files = secrets.map { (StorageRules.expand($0.path), $0) }.filter { FileManager.default.fileExists(atPath: $0.0) }
        guard !files.isEmpty, let r = runCommand("/usr/sbin/lsof", ["-Fpcn", "--"] + files.map(\.0), timeout: 10) else { return [] }
        var out: [Finding] = []
        var pid = "", command = ""
        for line in r.output.split(separator: "\n") {
            switch line.first {
            case "p": pid = String(line.dropFirst())
            case "c": command = String(line.dropFirst())
            case "n":
                let name = String(line.dropFirst())
                guard let secret = files.first(where: { $0.0 == name })?.1,
                      !secret.owners.contains(where: { command.hasPrefix($0) }) else { continue }
                out.append(Finding(id: "secret:\(command):\(name)", severity: .warning, kind: "Secret file",
                                   title: "\(command) has \(secret.what) open",
                                   detail: "PID \(pid). Expected only from \(secret.owners.joined(separator: ", ")). Check what \(command) is.", path: name))
            default: break
            }
        }
        return out
    }

    /// Heavy: verifies the code signature of each program (reads every executable, so it
    /// takes tens of seconds and one core). Unsigned or broken signatures are reported.
    public static func signatures(_ paths: [String], progress: @Sendable (Double) -> Void) -> [Finding] {
        var out: [Finding] = []
        let unique = Array(Set(paths)).sorted()
        for (i, path) in unique.enumerated() {
            progress(Double(i) / Double(max(unique.count, 1)))
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &code) == errSecSuccess, let code else { continue }
            let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSDoNotValidateResources), nil)
            if status == errSecCSUnsigned {
                out.append(Finding(id: "unsigned:\(path)", severity: .notice, kind: "Signature", title: "\((path as NSString).lastPathComponent) is not signed",
                                   detail: "Common for tools you built or installed by hand; unusual for apps.", path: path))
            } else if status != errSecSuccess {
                out.append(Finding(id: "badsig:\(path)", severity: .warning, kind: "Signature", title: "\((path as NSString).lastPathComponent) has a broken signature",
                                   detail: "The program changed after it was signed (error \(status)). Reinstall it if you don't know why.", path: path))
            }
        }
        progress(1)
        return out
    }
}
