import Foundation
import HawkKit
import Testing

@Suite struct AndroidPowerTests {
    private let parts = [
        "idle": "system-excidle,com.android.shell,2000\nuser,com.example.tracker,10123\n",
        "bucket": "40\n",
        "ops": "Uid mode: COARSE_LOCATION: allow\nRUN_IN_BACKGROUND: allow; time=+1d\nRUN_ANY_IN_BACKGROUND: ignore; rejectTime=+2h\nREAD_CONTACTS: ignore\n",
        "perms": "      android.permission.ACCESS_FINE_LOCATION: granted=true, flags=[ USER_SET ]\n      android.permission.ACCESS_BACKGROUND_LOCATION: granted=false\n",
        "location": "3\n", "power": "1\n", "alarm": "12\n", "services": "0\n",
    ]

    @Test func readsAnAppsBackgroundState() {
        let s = AppPowerState.parse(parts, package: "com.example.tracker")
        #expect(s.exemption == "user" && s.bucket == 40 && s.bucketName == "Rare")
        #expect(s.appOps == ["COARSE_LOCATION": "allow", "RUN_IN_BACKGROUND": "allow", "RUN_ANY_IN_BACKGROUND": "ignore"])
        #expect(s.fineLocation == true && s.backgroundLocation == false && s.coarseLocation == nil)
        #expect(s.locationRequests == 3 && s.wakelocks == 1 && s.alarms == 12 && s.foregroundServices == 0)
        #expect(AppPowerState.parse(parts, package: "com.example.other").exemption == nil)
    }

    @Test func partsQuoteThePackage() {
        #expect(AppPowerState.parts("com.example.tracker")?["bucket"] == "am get-standby-bucket 'com.example.tracker'")
        #expect(AppPowerState.parts("bad; reboot") == nil)
    }

    @Test func everyForceHasItsUndo() {
        let forces: [PowerForce] = [.doze, .standbyBucket(package: "com.example.app", to: 45, from: 10), .inactive(package: "com.example.app"), .unplugBattery]
        #expect(forces.map(\.command) == ["dumpsys deviceidle force-idle", "am set-standby-bucket 'com.example.app' 45",
                                          "am set-inactive 'com.example.app' true", "dumpsys battery unplug"])
        #expect(forces.map(\.undo) == ["dumpsys deviceidle unforce", "am set-standby-bucket 'com.example.app' 10",
                                       "am set-inactive 'com.example.app' false", "dumpsys battery reset"])
        #expect(PowerForce.inactive(package: "x y").command == nil)
    }

    @Test func forcedStatesAreRememberedAndUndone() async throws {
        let fake = FakeDeviceSession()
        let store = DeviceStore(root: FileManager.default.temporaryDirectory.appending(path: "hawk-power-\(UUID().uuidString)"))
        #expect(await PowerForces.apply(.doze, on: fake, deviceName: "Test phone", store: store))
        #expect(await PowerForces.apply(.unplugBattery, on: fake, deviceName: "Test phone", store: store))
        #expect(await PowerForces.load(fake.id, store: store) == [.doze, .unplugBattery])
        await PowerForces.undoAll(on: fake, deviceName: "Test phone", store: store)
        #expect(await PowerForces.load(fake.id, store: store).isEmpty)
        #expect(fake.calls.suffix(2) == ["shell dumpsys battery reset", "shell dumpsys deviceidle unforce"])
        let log = try String(contentsOf: try await store.folder(fake.id).appending(path: ActionLog.fileName), encoding: .utf8)
        #expect(log.contains("| Change | Doze forced | done |") && log.contains("| Change | Undo: Doze forced | done |"))
    }

    @Test func aFailedUndoIsKeptForNextTime() async {
        let fake = FakeDeviceSession()
        let store = DeviceStore(root: FileManager.default.temporaryDirectory.appending(path: "hawk-power-\(UUID().uuidString)"))
        _ = await PowerForces.apply(.doze, on: fake, deviceName: "T", store: store)
        fake.answer(shell: "dumpsys deviceidle unforce", with: "", status: 1)
        await PowerForces.undoAll(on: fake, deviceName: "T", store: store)
        #expect(await PowerForces.load(fake.id, store: store) == [.doze])
    }
}
