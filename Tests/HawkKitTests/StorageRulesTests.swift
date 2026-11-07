import HawkKit
import Foundation
import Testing

private func entry(_ id: String, risk: String = "safe", category: String = "tools", reclaim: String? = nil, paths: [String] = []) throws -> StorageEntry {
    var json: [String: Any] = ["id": id, "category": category, "name": id, "risk": risk, "paths": paths]
    if let reclaim { json["reclaim"] = reclaim }
    return try JSONDecoder().decode(StorageEntry.self, from: JSONSerialization.data(withJSONObject: json))
}

private let idle = RunningState(bundleIDs: [], commandLines: [])
private let home = NSHomeDirectory()

@Suite struct StorageRulesTests {
    @Test func whatsappIsNeverDeletableWhateverTheRegistrySays() throws {
        // Even a registry entry wrongly marked safe cannot delete WhatsApp data.
        let e = try entry("whatsapp-media", risk: "safe")
        for path in ["\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared",
                     "\(home)/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media/x@lid",
                     "\(home)/Library/Containers/net.whatsapp.WhatsApp/Data"] {
            #expect(StorageRules.verdict(entry: e, path: path, running: idle, lastTouched: nil).isBlocked)
        }
    }

    @Test func whatsappCleanupCommandsNeverRun() throws {
        let e = try entry("whatsapp-media", risk: "safe", reclaim: "rm -rf ~/x", paths: ["~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared"])
        #expect(StorageRules.runnableReclaim(e) == nil)
    }

    @Test func neverAndPersonalEntriesAreBlocked() throws {
        #expect(StorageRules.verdict(entry: try entry("xcode-archives", risk: "never"), path: "\(home)/Library/Caches/x",
                                     running: idle, lastTouched: nil).isBlocked)
        #expect(StorageRules.verdict(entry: try entry("old-game", risk: "care", category: "personal"), path: "\(home)/Games/x",
                                     running: idle, lastTouched: nil).isBlocked)
    }

    @Test func pathsOutsideHomeOrTooShallowAreBlocked() throws {
        let e = try entry("homebrew-cache")
        #expect(StorageRules.verdict(entry: e, path: "/opt/homebrew/Caskroom/x", running: idle, lastTouched: nil).isBlocked)
        #expect(StorageRules.verdict(entry: e, path: "\(home)/Library", running: idle, lastTouched: nil).isBlocked)
        #expect(StorageRules.verdict(entry: e, path: "\(home)/Library/Caches/Homebrew", running: idle, lastTouched: nil) == .allowed)
    }

    @Test func chromeCacheIsBlockedWhileChromeIsOpen() throws {
        let e = try entry("chrome-cache")
        let path = "\(home)/Library/Caches/Google/Chrome"
        let open = RunningState(bundleIDs: ["com.google.Chrome"], commandLines: [])
        #expect(StorageRules.verdict(entry: e, path: path, running: open, lastTouched: nil).isBlocked)
        #expect(StorageRules.verdict(entry: e, path: path, running: idle, lastTouched: nil) == .allowed)
    }

    @Test func spotifyAllowsOnlyItsPureCacheFoldersWhileOpen() throws {
        let e = try entry("spotify-cache")
        let open = RunningState(bundleIDs: ["com.spotify.client"], commandLines: [])
        #expect(StorageRules.verdict(entry: e, path: "\(home)/Library/Caches/com.spotify.client/Data", running: open, lastTouched: nil) == .allowed)
        #expect(StorageRules.verdict(entry: e, path: "\(home)/Library/Caches/com.spotify.client", running: open, lastTouched: nil).isBlocked)
    }

    @Test func aRunningEmulatorBlocksItsAVD() throws {
        let e = try entry("android-avd", risk: "care")
        let emulator = RunningState(bundleIDs: [], commandLines: ["/sdk/emulator/qemu-system-aarch64 -avd pixel_test -no-snapshot"])
        #expect(StorageRules.verdict(entry: e, path: "\(home)/.android/avd/pixel_test.avd", running: emulator, lastTouched: nil).isBlocked)
        #expect(!StorageRules.verdict(entry: e, path: "\(home)/.android/avd/other.avd", running: emulator, lastTouched: nil).isBlocked)
    }

    @Test func recentlyTouchedProjectsAskForCaution() throws {
        let e = try entry("node-modules")
        let v = StorageRules.verdict(entry: e, path: "\(home)/apps/x/node_modules", running: idle, lastTouched: Date().addingTimeInterval(-86400))
        #expect(v != .allowed && !v.isBlocked)
    }

    @Test func onlyCompleteCommandsRun() throws {
        #expect(StorageRules.runnableReclaim(try entry("a", reclaim: "brew cleanup -s --prune=all")) == "brew cleanup -s --prune=all")
        #expect(StorageRules.runnableReclaim(try entry("b", reclaim: "rm -rf ~/x/<version>")) == nil)
        #expect(StorageRules.runnableReclaim(try entry("c", reclaim: "sudo rm -rf /System/x")) == nil)
        #expect(StorageRules.runnableReclaim(try entry("d", reclaim: "# Docker Desktop > Reset")) == nil)
        #expect(StorageRules.runnableReclaim(try entry("e", reclaim: "docker image prune   # -a for all")) == "docker image prune")
        #expect(StorageRules.runnableReclaim(try entry("f", risk: "never", reclaim: "rm -rf ~/x")) == nil)
    }
}

@Suite struct StorageParsingTests {
    @Test func unknownRiskIsTreatedAsNever() throws {
        #expect(try entry("x", risk: "maybe").risk == .never)
    }

    @Test func dockerSizesParse() {
        #expect(Docker.parseSize("1.5GB") == 1_500_000_000)
        #expect(Docker.parseSize("512MB") == 512_000_000)
        #expect(Docker.parseSize("0B") == 0)
    }

    @Test func growthUsesTheWindow() {
        let now = Date()
        let series = [(now.addingTimeInterval(-40 * 86400), 1.0), (now.addingTimeInterval(-20 * 86400), 2.0), (now, 5.0)]
        #expect(StorageHistory.growth(series, days: 30, now: now) == 3.0)
    }
}
