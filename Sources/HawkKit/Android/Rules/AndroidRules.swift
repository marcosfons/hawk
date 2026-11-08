import Foundation

/// Something Hawk would change on a device. Later plans add cases with their rules
/// and tests; every action goes through `AndroidRules.verdict` at the moment of acting.
public enum AndroidAction: Sendable, Equatable {
    case forceStop(package: String)
    case clearCache(package: String)
    case clearData(package: String)
    case uninstall(package: String)
    case disable(package: String)
    case enable(package: String)
    /// Installing adds or updates an app; the target is the file name.
    case install(file: String)
    case deletePath(String)

    public var name: String {
        switch self {
        case .forceStop: "Force stop"
        case .clearCache: "Clear cache"
        case .clearData: "Clear data"
        case .uninstall: "Uninstall"
        case .disable: "Disable"
        case .enable: "Enable"
        case .install: "Install"
        case .deletePath: "Delete"
        }
    }

    public var target: String {
        switch self {
        case .forceStop(let p), .clearCache(let p), .clearData(let p), .uninstall(let p), .disable(let p), .enable(let p): p
        case .install(let file): file
        case .deletePath(let path): path
        }
    }
}

/// What Hawk knows about the device at the moment of acting.
public struct DeviceFacts: Sendable, Equatable {
    /// From `dpm list-owners` / `dumpsys device_policy`.
    public var deviceOwner: String?
    public var profileOwners: Set<String>
    /// The current home app.
    public var launcher: String?

    public init(deviceOwner: String? = nil, profileOwners: Set<String> = [], launcher: String? = nil) {
        self.deviceOwner = deviceOwner
        self.profileOwners = profileOwners
        self.launcher = launcher
    }
}

/// The rules every change to a device passes, rechecked at the moment of acting.
/// Root does not lift them: a protected package or path stays protected.
public enum AndroidRules {
    public enum Verdict: Sendable, Equatable {
        case allowed
        case blocked(String)

        public var isAllowed: Bool { self == .allowed }
    }

    /// Packages without which the phone cannot be used or managed.
    public static let protectedPackages: Set<String> = [
        "android",
        "com.android.settings",
        "com.android.systemui",
        "com.android.phone",
        "com.android.shell",
        "com.android.providers.telephony",
        "com.android.packageinstaller",
        "com.google.android.packageinstaller",
        "com.android.permissioncontroller",
        "com.google.android.permissioncontroller",
        "com.android.launcher3",
        "com.google.android.apps.nexuslauncher",
        "com.sec.android.app.launcher",
        "com.miui.home",
    ]

    /// WhatsApp's data is never deleted or cleared, not even with confirmation.
    public static let neverClearedPackages: Set<String> = ["com.whatsapp", "com.whatsapp.w4b"]

    /// Paths never deleted, nor anything above them.
    public static let protectedPaths: [String] = [
        "/sdcard/WhatsApp",
        "/sdcard/Android/media/com.whatsapp",
        "/sdcard/Android/media/com.whatsapp.w4b",
        "/sdcard/Android/data/com.whatsapp",
        "/sdcard/Android/data/com.whatsapp.w4b",
        "/storage/emulated/0/WhatsApp",
        "/storage/emulated/0/Android/media/com.whatsapp",
        "/storage/emulated/0/Android/media/com.whatsapp.w4b",
        "/storage/emulated/0/Android/data/com.whatsapp",
        "/storage/emulated/0/Android/data/com.whatsapp.w4b",
    ]

    /// Folders that may never be deleted themselves (their contents may, by later rules).
    public static let protectedRoots: Set<String> = [
        "/", "/system", "/vendor", "/product", "/data", "/data/data", "/data/app", "/data/media",
        "/sdcard", "/storage", "/storage/emulated", "/storage/emulated/0", "/sdcard/Android", "/storage/emulated/0/Android",
        "/sdcard/DCIM", "/storage/emulated/0/DCIM",
    ]

    public static func verdict(_ action: AndroidAction, facts: DeviceFacts) -> Verdict {
        switch action {
        case .enable(let p):
            // Turning an app back on never loses anything.
            return ShellQuote.isPackageName(p) ? .allowed : .blocked("Not a package name")
        case .install:
            // Android itself refuses a downgrade or a different signature (no -d, no
            // uninstall first), so an install never loses an app's data.
            return .allowed
        case .forceStop(let p), .clearCache(let p), .clearData(let p), .uninstall(let p), .disable(let p):
            guard ShellQuote.isPackageName(p) else { return .blocked("Not a package name") }
            if protectedPackages.contains(p) { return .blocked("\(p) is part of the system Hawk never changes") }
            if p == facts.launcher { return .blocked("\(p) is the home app") }
            if p == facts.deviceOwner || facts.profileOwners.contains(p) { return .blocked("\(p) manages this device") }
            if neverClearedPackages.contains(p), action != .forceStop(package: p) { return .blocked("WhatsApp data is never deleted") }
            return .allowed
        case .deletePath(let path):
            guard ShellQuote.isRemotePath(path) else { return .blocked("Not a valid path") }
            let p = normalise(path)
            if protectedRoots.contains(p) { return .blocked("\(p) is a system folder") }
            for protected in protectedPaths where p == protected || p.hasPrefix(protected + "/") || protected.hasPrefix(p + "/") {
                return .blocked("WhatsApp data is never deleted")
            }
            return .allowed
        }
    }

    /// Without duplicate or trailing slashes, and with "." parts dropped.
    static func normalise(_ path: String) -> String {
        "/" + path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
}
