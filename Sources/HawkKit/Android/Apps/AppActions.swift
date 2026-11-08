import Foundation

/// The shell commands behind the app actions (requirements 3.3), and running them
/// through `AndroidRules` (rechecked at the moment of acting) and `ActionLog`.
public enum AppActions {
    /// Device owner, profile owners and home app, read at the moment of acting.
    public static let factsParts: [String: String] = [
        "owners": "dpm list-owners",
        "home": "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME",
        "help": "pm help 2>&1 | grep -c cache-only",
    ]

    /// "User 0: admin=com.example.mdm/.Receiver,DeviceOwner" lines; and the last line
    /// of resolve-activity, "com.example.home/.Launcher".
    public static func parseFacts(_ parts: [String: String]) -> (facts: DeviceFacts, cacheOnly: Bool) {
        var facts = DeviceFacts()
        for line in (parts["owners"] ?? "").prefix(64 * 1024).split(whereSeparator: \.isNewline) {
            guard let range = line.range(of: "admin=") else { continue }
            let rest = line[range.upperBound...]
            guard let pkg = rest.split(separator: "/").first.map(String.init), ShellQuote.isPackageName(pkg) else { continue }
            if line.contains("DeviceOwner") { facts.deviceOwner = pkg } else { facts.profileOwners.insert(pkg) }
        }
        if let last = (parts["home"] ?? "").split(whereSeparator: \.isNewline).last,
           let pkg = last.split(separator: "/").first.map({ String($0).trimmingCharacters(in: .whitespaces) }),
           ShellQuote.isPackageName(pkg) {
            facts.launcher = pkg
        }
        let cacheOnly = (Int((parts["help"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0
        return (facts, cacheOnly)
    }

    /// The command for an action on a package; nil when it cannot be done this way
    /// (clear cache without `pm clear --cache-only`).
    public static func command(_ action: AndroidAction, isSystem: Bool, cacheOnly: Bool) -> String? {
        guard let pkg = ShellQuote.package(action.target) else { return nil }
        switch action {
        case .forceStop: return "am force-stop \(pkg)"
        case .clearCache: return cacheOnly ? "pm clear --cache-only \(pkg)" : nil
        case .clearData: return "pm clear \(pkg)"
        // A system app cannot be removed, only uninstalled for user 0 (reversible with
        // `cmd package install-existing`).
        case .uninstall: return isSystem ? "pm uninstall --user 0 \(pkg)" : "pm uninstall \(pkg)"
        case .disable: return "pm disable-user --user 0 \(pkg)"
        case .enable: return "pm enable \(pkg)"
        case .install, .change, .deletePath: return nil
        }
    }

    /// Starts the app's launcher activity.
    public static func openCommand(_ package: String) -> String? {
        ShellQuote.package(package).map { "monkey -p \($0) -c android.intent.category.LAUNCHER 1" }
    }

    /// `pm path` lines, "package:/data/app/~~x/com.example-y/base.apk": every split.
    public static func parseApkPaths(_ text: String) -> [String] {
        text.prefix(64 * 1024).split(whereSeparator: \.isNewline).prefix(64).compactMap { line in
            guard line.hasPrefix("package:") else { return nil }
            let path = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            return ShellQuote.isRemotePath(path) && path.hasSuffix(".apk") ? path : nil
        }
    }

    /// A local file name for a pulled split: the package, then the split's own name
    /// reduced to plain characters, so nothing from the device can choose a path.
    public static func localName(package: String, remote: String) -> String {
        let last = remote.split(separator: "/").last.map(String.init) ?? "base.apk"
        let plain = String(last.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) ? $0 : "_" }).prefix(80)
        let name = plain.hasPrefix(".") || plain.isEmpty ? "base.apk" : String(plain)
        return "\(package)-\(name.hasSuffix(".apk") ? name : name + ".apk")"
    }

    /// `adb install` for one APK, `install-multiple` for a split set; `-r` keeps data.
    public static func installArguments(_ files: [URL]) -> [String]? {
        let apks = files.filter { $0.pathExtension.lowercased() == "apk" }
        guard !apks.isEmpty, apks.count == files.count, apks.count <= 64 else { return nil }
        return (apks.count == 1 ? ["install", "-r"] : ["install-multiple", "-r"]) + apks.map(\.path)
    }

    /// `pm`/`am` print "Success" or nothing on success, and "Failure [...]" or an
    /// exception otherwise; the status is not always reliable.
    public static func succeeded(_ result: ShellResult) -> Bool {
        let text = (result.stdout + result.stderr).lowercased()
        return result.status == 0 && !text.contains("failure") && !text.contains("exception") && !text.contains("error")
    }

    /// Checks the rules with fresh facts, runs the command, logs the outcome.
    public static func perform(_ action: AndroidAction, isSystem: Bool, on session: any DeviceSession,
                               deviceName: String, store: DeviceStore?) async -> ActionLog.Result {
        let result: ActionLog.Result
        do {
            let parts = try await session.shellBatch(factsParts, timeout: .seconds(10))
            let (facts, cacheOnly) = parseFacts(parts)
            if case .blocked(let why) = AndroidRules.verdict(action, facts: facts) {
                result = .blocked(why)
            } else if let command = command(action, isSystem: isSystem, cacheOnly: cacheOnly) {
                let out = try await session.shell(command, timeout: .seconds(30))
                result = succeeded(out) ? .done : .failed(String((out.stdout + out.stderr).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200)))
            } else {
                result = .failed("Not available on this device")
            }
        } catch {
            result = .failed((error as? AdbError)?.summary ?? error.localizedDescription)
        }
        if let store {
            do { try await ActionLog.append(device: deviceName, action: action, result: result, id: session.id, store: store) } catch {
                Log.app.error("Could not write the Android action log: \(error.localizedDescription)")
            }
        }
        Log.app.info("Android app action \(action.name): \(result == .done ? "done" : "not done")")
        return result
    }
}
