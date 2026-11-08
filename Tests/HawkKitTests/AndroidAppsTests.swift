import Foundation
import HawkKit
import Testing

@Suite struct AndroidAppCatalogTests {
    private let index = PackageIndex.parse([
        "all": """
        package:com.example.game versionCode:12 uid:10100
        package:com.example.tool versionCode:3 uid:10101
        package:com.android.settings versionCode:35 uid:1000
        package:com.example.bloat versionCode:1 uid:10102
        """,
        "user": "package:com.example.game\npackage:com.example.tool\n",
    ])
    private let shell = [
        "installers": "package:com.example.game  installer=com.android.vending\npackage:com.example.tool  installer=null\npackage:com.android.settings  installer=null\n",
        "disabled": "package:com.example.bloat\n",
    ]

    @Test func buildsFromTheShellAlone() {
        let apps = AppCatalog.build(index: index, shell: shell)
        #expect(apps.count == 4)
        let game = apps.first { $0.name == "com.example.game" }
        #expect(game?.source == "Play Store" && game?.isSystem == false && game?.enabled == true && game?.versionCode == 12)
        #expect(apps.first { $0.name == "com.example.tool" }?.source == "Sideloaded")
        #expect(apps.first { $0.name == "com.android.settings" }?.source == "Preloaded")
        #expect(apps.first { $0.name == "com.example.bloat" }?.enabled == false)
    }

    @Test func helperAndSizesAreMergedIn() throws {
        let helper = HelperOutput.parse("A\tcom.example.game\t12\t1.2.0\t0\t1\t1700000000000\t1800000000000\t35\tcom.android.vending\nD\n").apps
        let storage = DeviceStorage.parse(["diskstats": "Package Names: [\"com.example.game\"]\nApp Sizes: [100]\nApp Data Sizes: [20]\nCache Sizes: [5]\n"])
        var labelled = index
        labelled.setLabel("Fake Game", for: "com.example.game")
        let game = try #require(AppCatalog.build(index: labelled, shell: shell, helper: helper, storage: storage).first { $0.name == "com.example.game" })
        #expect(game.title == "Fake Game" && game.versionName == "1.2.0" && game.targetSdk == 35)
        #expect(game.lastUpdate == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(game.totalSize == 125)
    }

    @Test func filtersAndSearch() {
        var labelled = index
        labelled.setLabel("Fake Game", for: "com.example.game")
        let apps = AppCatalog.build(index: labelled, shell: shell)
        #expect(AppCatalog.filter(apps, .user, query: "").count == 2)
        #expect(AppCatalog.filter(apps, .system, query: "").count == 2)
        #expect(AppCatalog.filter(apps, .disabled, query: "").map(\.name) == ["com.example.bloat"])
        #expect(AppCatalog.filter(apps, .sideloaded, query: "").map(\.name) == ["com.example.tool"])
        #expect(AppCatalog.filter(apps, .all, query: "fake g").map(\.name) == ["com.example.game"])
        #expect(AppCatalog.filter(apps, .all, query: "SETTINGS").count == 1)
    }

    @Test func iconsOnlyForNewVersionsUserAppsFirst() {
        let apps = AppCatalog.build(index: index, shell: shell)
        let batches = AppCatalog.iconBatches(apps, cached: ["com.example.tool-3"], batch: 2)
        #expect(batches == [["com.example.game", "com.android.settings"], ["com.example.bloat"]])
        let all = Set(apps.map(\.iconKey))
        #expect(AppCatalog.iconBatches(apps, cached: all).isEmpty)
    }

    @Test func garbageListsAreSafe() {
        #expect(AppCatalog.parseInstallers("package:bad name installer=x\npackage:com.a.b installer=" + String(repeating: "x", count: 500)).isEmpty)
        #expect(AppCatalog.parsePackages("package:com.example.a; reboot\npackage:\n\u{0}").isEmpty)
    }
}

@Suite struct AndroidAppActionsTests {
    @Test func factsFromOwnersHomeAndHelp() {
        let (facts, cacheOnly) = AppActions.parseFacts([
            "owners": "User 0: admin=com.example.mdm/.Receiver,DeviceOwner\nUser 150: admin=com.example.work/.Agent,ProfileOwner\n",
            "home": "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\ncom.example.home/.Launcher\n",
            "help": "2\n",
        ])
        #expect(facts == DeviceFacts(deviceOwner: "com.example.mdm", profileOwners: ["com.example.work"], launcher: "com.example.home"))
        #expect(cacheOnly)
        #expect(!AppActions.parseFacts(["help": "0"]).cacheOnly)
    }

    @Test func commands() {
        #expect(AppActions.command(.forceStop(package: "com.example.app"), isSystem: false, cacheOnly: true) == "am force-stop 'com.example.app'")
        #expect(AppActions.command(.clearCache(package: "com.example.app"), isSystem: false, cacheOnly: true) == "pm clear --cache-only 'com.example.app'")
        #expect(AppActions.command(.clearCache(package: "com.example.app"), isSystem: false, cacheOnly: false) == nil)
        #expect(AppActions.command(.uninstall(package: "com.example.app"), isSystem: true, cacheOnly: true) == "pm uninstall --user 0 'com.example.app'")
        #expect(AppActions.command(.uninstall(package: "com.example.app"), isSystem: false, cacheOnly: true) == "pm uninstall 'com.example.app'")
        #expect(AppActions.command(.disable(package: "com.example.app"), isSystem: false, cacheOnly: true) == "pm disable-user --user 0 'com.example.app'")
        #expect(AppActions.command(.forceStop(package: "com.example.app; reboot"), isSystem: false, cacheOnly: true) == nil)
    }

    @Test func successIsReadFromTheOutput() {
        #expect(AppActions.succeeded(ShellResult(stdout: "Success\n")))
        #expect(AppActions.succeeded(ShellResult(stdout: "")))
        #expect(!AppActions.succeeded(ShellResult(stdout: "Failure [DELETE_FAILED_INTERNAL_ERROR]\n")))
        #expect(!AppActions.succeeded(ShellResult(stdout: "Exception occurred while executing 'clear':", status: 0)))
        #expect(!AppActions.succeeded(ShellResult(stdout: "", status: 255)))
    }

    @Test func rulesAreRecheckedWithFreshFactsAndLogged() async throws {
        let fake = FakeDeviceSession()
        fake.answer(batch: "owners", with: "User 0: admin=com.example.mdm/.Receiver,DeviceOwner\n")
        fake.answer(batch: "home", with: "com.example.home/.Launcher\n")
        fake.answer(batch: "help", with: "2\n")
        let store = DeviceStore(root: FileManager.default.temporaryDirectory.appending(path: "hawk-actions-\(UUID().uuidString)"))
        let blocked = await AppActions.perform(.clearData(package: "com.example.mdm"), isSystem: false, on: fake, deviceName: "Test phone", store: store)
        #expect(blocked == .blocked("com.example.mdm manages this device"))
        #expect(!fake.calls.contains { $0.hasPrefix("shell pm clear") })
        fake.answer(shell: "pm clear --cache-only 'com.example.debugapp'", with: "Success\n")
        let done = await AppActions.perform(.clearCache(package: "com.example.debugapp"), isSystem: false, on: fake, deviceName: "Test phone", store: store)
        #expect(done == .done)
        let log = try String(contentsOf: try await store.folder(fake.id).appending(path: ActionLog.fileName), encoding: .utf8)
        #expect(log.contains("blocked: com.example.mdm manages this device") && log.contains("| Clear cache | com.example.debugapp | done |"))
    }

    @Test func enableIsAlwaysAllowedForAValidName() {
        let facts = DeviceFacts(launcher: "com.example.home")
        #expect(AndroidRules.verdict(.enable(package: "com.android.settings"), facts: facts).isAllowed)
        #expect(!AndroidRules.verdict(.enable(package: "bad name"), facts: facts).isAllowed)
    }
}
