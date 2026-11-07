// swift-tools-version: 6.2
import PackageDescription

let swift6: [SwiftSetting] = [.swiftLanguageMode(.v6)]

let package = Package(
    name: "hawk",
    platforms: [.macOS("26.0")],
    targets: [
        // Sensors, stats, processes, storage rules, fan curve, helper protocol. No UI.
        .target(name: "HawkKit", swiftSettings: swift6,
                linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreServices"), .linkedLibrary("sqlite3")]),
        // The app. Views and models run on the main actor; sampling runs in `Engine`.
        .executableTarget(name: "HawkApp", dependencies: ["HawkKit"],
                          swiftSettings: swift6 + [.defaultIsolation(MainActor.self)]),
        // Root helper started by launchd: the only process that writes fan speeds.
        .executableTarget(name: "hawkd", dependencies: ["HawkKit"]),
        // Command-line monitor and experiments.
        .executableTarget(name: "hawk", dependencies: ["HawkKit"]),
        .testTarget(name: "HawkKitTests", dependencies: ["HawkKit"], swiftSettings: swift6),
    ],
    swiftLanguageModes: [.v5]
)
