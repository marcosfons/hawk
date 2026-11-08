import Foundation

/// A local risk scan (requirements 8.1): flags worth a look, not "infected".
/// Nothing leaves the Mac; no root needed.
public enum AndroidSecurityScan {
    public enum Flag: String, Sendable, CaseIterable, Codable {
        case sideloaded, accessibility, deviceAdmin, notificationListener, overlay, installsApps
        case sms, callLog, defaultSMS, defaultDialer, vpn, usageAccess, hiddenIcon

        public var title: String {
            switch self {
            case .sideloaded: "Sideloaded"
            case .accessibility: "Accessibility service"
            case .deviceAdmin: "Device admin"
            case .notificationListener: "Reads notifications"
            case .overlay: "Draws over other apps"
            case .installsApps: "Installs other apps"
            case .sms: "Reads SMS"
            case .callLog: "Reads call log"
            case .defaultSMS: "Default SMS app"
            case .defaultDialer: "Default phone app"
            case .vpn: "VPN"
            case .usageAccess: "Usage access"
            case .hiddenIcon: "No launcher icon"
            }
        }

        /// How much it adds to an app's score: access that can watch or control the
        /// phone counts most.
        var weight: Int {
            switch self {
            case .accessibility, .deviceAdmin, .notificationListener: 3
            case .sms, .callLog, .installsApps, .vpn, .hiddenIcon: 2
            case .sideloaded, .overlay, .usageAccess, .defaultSMS, .defaultDialer: 1
            }
        }
    }

    public struct AppRisk: Sendable, Equatable, Identifiable {
        public let package: String
        public let flags: [Flag]
        public var score: Int { flags.reduce(0) { $0 + $1.weight } }
        public var id: String { package }
    }

    public struct Result: Sendable, Equatable {
        public var apps: [AppRisk] = []
        /// Device-wide findings (Play Protect off...).
        public var device: [String] = []
    }

    public static let parts: [String: String] = [
        "overlay": "cmd appops query-op SYSTEM_ALERT_WINDOW allow",
        "installs": "cmd appops query-op REQUEST_INSTALL_PACKAGES allow",
        "sms": "cmd appops query-op READ_SMS allow",
        "calllog": "cmd appops query-op READ_CALL_LOG allow",
        "vpn": "cmd appops query-op ACTIVATE_VPN allow",
        "usage": "cmd appops query-op GET_USAGE_STATS allow",
        "a11y": "settings get secure enabled_accessibility_services",
        "listeners": "settings get secure enabled_notification_listeners",
        "verifier": "settings get global package_verifier_enable",
        "smsRole": "cmd role get-role-holders android.app.role.SMS",
        "dialerRole": "cmd role get-role-holders android.app.role.DIALER",
        "admins": "dumpsys device_policy 2>/dev/null | grep -oE 'admin=ComponentInfo\\{[A-Za-z0-9_.]+/'",
        "launchers": "cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER",
        "installers": "pm list packages -i --user 0 -3",
    ]

    /// Flags for user apps only: system apps hold these as part of the phone.
    public static func parse(_ p: [String: String], userApps: Set<String>) -> Result {
        func packages(_ key: String) -> Set<String> {
            Set((p[key] ?? "").prefix(256 * 1024).split(whereSeparator: { $0.isNewline || $0 == ":" || $0 == " " }).compactMap { token in
                let t = token.replacingOccurrences(of: "admin=ComponentInfo{", with: "")
                let name = String(t.split(separator: "/").first ?? "")
                return ShellQuote.isPackageName(name) ? name : nil
            })
        }
        let installers = AppCatalog.parseInstallers(p["installers"] ?? "")
        let stores: Set<String> = ["com.android.vending", "com.sec.android.app.samsungapps", "com.amazon.venezia", "org.fdroid.fdroid",
                                   "com.huawei.appmarket", "com.xiaomi.market"]
        let launchers = packages("launchers")
        let sets: [(Flag, Set<String>)] = [
            (.accessibility, packages("a11y")), (.notificationListener, packages("listeners")), (.deviceAdmin, packages("admins")),
            (.overlay, packages("overlay")), (.installsApps, packages("installs")), (.sms, packages("sms")), (.callLog, packages("calllog")),
            (.vpn, packages("vpn")), (.usageAccess, packages("usage")), (.defaultSMS, packages("smsRole")), (.defaultDialer, packages("dialerRole")),
        ]
        var result = Result()
        for app in userApps.sorted() {
            var flags = sets.filter { $0.1.contains(app) }.map(\.0)
            if let installer = installers[app], !stores.contains(installer) { flags.insert(.sideloaded, at: 0) }
            if installers[app] == nil, !installers.isEmpty { flags.insert(.sideloaded, at: 0) }
            if !launchers.isEmpty, !launchers.contains(app) { flags.append(.hiddenIcon) }
            if !flags.isEmpty { result.apps.append(AppRisk(package: app, flags: flags)) }
        }
        result.apps.sort { $0.score != $1.score ? $0.score > $1.score : $0.package < $1.package }
        if (p["verifier"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == "0" {
            result.device.append("Play Protect app verification is off")
        }
        return result
    }
}

/// Preinstalled apps commonly removed (requirements 8.2), with how safe that is.
/// A small built-in list; the source of a fuller one is an open question.
public struct BloatEntry: Sendable, Equatable, Identifiable {
    public enum Safety: String, Sendable, CaseIterable { case safe = "Safe", probably = "Probably safe", risky = "Risky" }
    public let package: String
    public let vendor: String
    public let what: String
    public let safety: Safety
    public var id: String { package }

    public static let known: [BloatEntry] = [
        .init(package: "com.facebook.appmanager", vendor: "Facebook", what: "Facebook app manager (preinstalled)", safety: .safe),
        .init(package: "com.facebook.services", vendor: "Facebook", what: "Facebook services (preinstalled)", safety: .safe),
        .init(package: "com.facebook.system", vendor: "Facebook", what: "Facebook installer (preinstalled)", safety: .safe),
        .init(package: "com.samsung.android.bixby.agent", vendor: "Samsung", what: "Bixby voice assistant", safety: .probably),
        .init(package: "com.samsung.android.bixby.wakeup", vendor: "Samsung", what: "Bixby wake word", safety: .probably),
        .init(package: "com.samsung.android.visionintelligence", vendor: "Samsung", what: "Bixby Vision", safety: .safe),
        .init(package: "com.samsung.android.app.tips", vendor: "Samsung", what: "Samsung Tips", safety: .safe),
        .init(package: "com.samsung.android.game.gamehome", vendor: "Samsung", what: "Game Launcher", safety: .probably),
        .init(package: "com.samsung.android.arzone", vendor: "Samsung", what: "AR Zone", safety: .safe),
        .init(package: "com.samsung.android.aremoji", vendor: "Samsung", what: "AR Emoji", safety: .probably),
        .init(package: "com.samsung.android.app.spage", vendor: "Samsung", what: "Samsung Free (left home screen)", safety: .safe),
        .init(package: "com.samsung.android.mdx", vendor: "Samsung", what: "Link to Windows", safety: .probably),
        .init(package: "com.microsoft.skydrive", vendor: "Microsoft", what: "OneDrive (preinstalled)", safety: .safe),
        .init(package: "com.microsoft.office.officehubrow", vendor: "Microsoft", what: "Microsoft 365 (preinstalled)", safety: .safe),
        .init(package: "com.linkedin.android", vendor: "Microsoft", what: "LinkedIn (preinstalled)", safety: .safe),
        .init(package: "com.netflix.partner.activation", vendor: "Netflix", what: "Netflix partner activation", safety: .safe),
        .init(package: "com.google.android.apps.tachyon", vendor: "Google", what: "Google Meet (Duo)", safety: .safe),
        .init(package: "com.google.android.videos", vendor: "Google", what: "Google TV", safety: .safe),
        .init(package: "com.google.android.apps.youtube.music", vendor: "Google", what: "YouTube Music", safety: .safe),
        .init(package: "com.google.android.feedback", vendor: "Google", what: "Market feedback agent", safety: .probably),
        .init(package: "com.miui.analytics", vendor: "Xiaomi", what: "MIUI analytics", safety: .safe),
        .init(package: "com.miui.msa.global", vendor: "Xiaomi", what: "MIUI system ads", safety: .safe),
        .init(package: "com.xiaomi.mipicks", vendor: "Xiaomi", what: "GetApps store", safety: .probably),
        .init(package: "com.samsung.android.knox.containercore", vendor: "Samsung", what: "Knox containers (Secure Folder needs it)", safety: .risky),
    ]

    /// The entries present on the device, minus anything AndroidRules protects.
    public static func present(_ installed: Set<String>) -> [BloatEntry] {
        known.filter { installed.contains($0.package) && !AndroidRules.protectedPackages.contains($0.package) }
    }
}

/// "Restore everything Hawk removed" (requirements 8.2), from the device's
/// actions.md: every disable and uninstall that was done, newest action per
/// package wins, turned into enable and reinstall.
public enum RemovalRestore {
    public static func pending(fromActionLog text: String) -> [AndroidAction] {
        var last: [String: String] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            // | time | device | action | target | result |
            guard cells.count >= 6, cells[5] == "done", ShellQuote.isPackageName(cells[4]) else { continue }
            let action = cells[3], pkg = cells[4]
            guard ["Disable", "Uninstall", "Enable", "Reinstall"].contains(action) else { continue }
            if last[pkg] == nil { order.append(pkg) }
            last[pkg] = action
        }
        return order.compactMap { pkg in
            switch last[pkg] {
            case "Disable": .enable(package: pkg)
            case "Uninstall": .reinstall(package: pkg)
            default: nil
            }
        }
    }
}
