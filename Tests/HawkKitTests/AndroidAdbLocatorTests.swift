import Foundation
import HawkKit
import Synchronization
import Testing

/// A made-up file system: paths to states, real paths to `adb version` output.
private final class FakeProbe: AdbProbe {
    private struct State { var files: [String: AdbPathState]; var outputs: [String: String]; var calls: [String] = [] }
    private let state: Mutex<State>

    init(files: [String: AdbPathState], outputs: [String: String]) {
        state = Mutex(State(files: files, outputs: outputs))
    }

    var versionCalls: [String] { state.withLock { $0.calls } }

    /// An update in place: same path, new modification date, new output.
    func replace(_ path: String, with file: AdbPathState, output: String) {
        state.withLock { $0.files[path] = file; $0.outputs[path] = output }
    }

    func inspect(_ path: String) -> AdbPathState { state.withLock { $0.files[path] ?? .missing } }

    func versionOutput(of path: String) -> String? {
        state.withLock { $0.calls.append(path); return $0.outputs[path] }
    }
}

private let home = "/Users/someone"
private let sdkAdb = "/Users/someone/Library/Android/sdk/platform-tools/adb"
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func versionText(_ proto: String = "1.0.41", _ release: String = "36.0.0-12345678") -> String {
    """
    Android Debug Bridge version \(proto)
    Version \(release)
    Installed as /somewhere/adb
    Running on Darwin 25.0.0 (arm64)
    """
}

private func env(_ vars: [String: String] = [:]) -> AdbLocator.Environment {
    .init(variables: vars, home: home)
}

@Suite struct AndroidAdbLocatorTests {
    @Test func parsesVersionOutput() {
        let v = AdbVersion.parse(versionText())
        #expect(v == AdbVersion(protocolVersion: "1.0.41", release: "36.0.0", build: "12345678"))
        #expect(v?.description == "36.0.0 (1.0.41)")
    }

    @Test func versionWithoutReleaseLineStillParses() {
        #expect(AdbVersion.parse("Android Debug Bridge version 1.0.39\n") == AdbVersion(protocolVersion: "1.0.39", release: ""))
    }

    @Test func garbageIsNotAVersion() {
        #expect(AdbVersion.parse("") == nil)
        #expect(AdbVersion.parse("zsh: command not found: adb") == nil)
        #expect(AdbVersion.parse("Android Debug Bridge version ") == nil)
        #expect(AdbVersion.parse("Android Debug Bridge version " + String(repeating: "9", count: 500)) == nil)
        #expect(AdbVersion.parse(String(repeating: "\u{0}x\n", count: 10_000)) == nil)
        // Truncated mid-line.
        #expect(AdbVersion.parse("Android Debug Br") == nil)
    }

    @Test func searchOrderFollowsThePlan() {
        let paths = AdbLocator.candidates(in: env([
            "ADB": "/custom/adb",
            "ANDROID_HOME": "/sdk",
            "PATH": "/usr/bin:/opt/tools/bin::/usr/local/bin",
        ])).map(\.path)
        #expect(paths == [
            "/custom/adb", "/sdk/platform-tools/adb", sdkAdb,
            "/usr/bin/adb", "/opt/tools/bin/adb", "/usr/local/bin/adb", "/opt/homebrew/bin/adb",
        ])
    }

    @Test func relativePathEntriesAreIgnored() {
        let paths = AdbLocator.candidates(in: env(["PATH": ".:bin:/usr/bin"])).map(\.path)
        #expect(!paths.contains { !$0.hasPrefix("/") })
    }

    @Test func symlinkToTheSdkIsOneCopyNotTwo() {
        let probe = FakeProbe(files: [
            sdkAdb: .executable(realPath: sdkAdb, modified: t0),
            "/usr/local/bin/adb": .executable(realPath: sdkAdb, modified: t0),
        ], outputs: [sdkAdb: versionText()])
        var locator = AdbLocator(probe: probe)
        let found = locator.locate(in: env(["PATH": "/usr/local/bin:/usr/bin"]))
        #expect(found.chosen?.path == sdkAdb)
        #expect(found.chosen?.aliases == ["/usr/local/bin/adb"])
        #expect(found.others.isEmpty)
        #expect(!found.hasVersionConflict)
        #expect(found.warnings.isEmpty)
        #expect(probe.versionCalls == [sdkAdb])
    }

    @Test func twoVersionsAreAConflict() {
        let probe = FakeProbe(files: [
            sdkAdb: .executable(realPath: sdkAdb, modified: t0),
            "/opt/homebrew/bin/adb": .executable(realPath: "/opt/homebrew/Caskroom/adb", modified: t0),
        ], outputs: [sdkAdb: versionText(), "/opt/homebrew/Caskroom/adb": versionText("1.0.41", "36.0.2-87654321")])
        var locator = AdbLocator(probe: probe)
        let found = locator.locate(in: env())
        #expect(found.chosen?.path == sdkAdb)
        #expect(found.others.map(\.path) == ["/opt/homebrew/bin/adb"])
        #expect(found.hasVersionConflict)
        #expect(found.warnings.first?.hasPrefix("Two adb versions installed") == true)
    }

    @Test func twoCopiesOfTheSameVersionAreNotAConflict() {
        let probe = FakeProbe(files: [
            sdkAdb: .executable(realPath: sdkAdb, modified: t0),
            "/opt/homebrew/bin/adb": .executable(realPath: "/opt/homebrew/Caskroom/adb", modified: t0),
        ], outputs: [sdkAdb: versionText(), "/opt/homebrew/Caskroom/adb": versionText()])
        var locator = AdbLocator(probe: probe)
        let found = locator.locate(in: env())
        #expect(found.others.count == 1)
        #expect(!found.hasVersionConflict)
    }

    @Test func environmentVariableWins() {
        let probe = FakeProbe(files: [
            "/custom/adb": .executable(realPath: "/custom/adb", modified: t0),
            sdkAdb: .executable(realPath: sdkAdb, modified: t0),
        ], outputs: ["/custom/adb": versionText(), sdkAdb: versionText()])
        var locator = AdbLocator(probe: probe)
        #expect(locator.locate(in: env(["ADB": "/custom/adb"])).chosen?.source == .environment)
    }

    @Test func danglingSymlinkIsReportedAndSkipped() {
        let probe = FakeProbe(files: [
            "/usr/local/bin/adb": .dangling(target: "/old/sdk/platform-tools/adb"),
            "/opt/homebrew/bin/adb": .executable(realPath: "/opt/homebrew/bin/adb", modified: t0),
        ], outputs: ["/opt/homebrew/bin/adb": versionText()])
        var locator = AdbLocator(probe: probe)
        let found = locator.locate(in: env(["PATH": "/usr/local/bin"]))
        #expect(found.chosen?.path == "/opt/homebrew/bin/adb")
        #expect(found.broken.map(\.path) == ["/usr/local/bin/adb"])
        #expect(found.broken.map(\.reason) == [.dangling(target: "/old/sdk/platform-tools/adb")])
        #expect(found.warnings == ["/usr/local/bin/adb points to /old/sdk/platform-tools/adb, which no longer exists"])
    }

    @Test func nothingFoundIsAStateNotACrash() {
        var locator = AdbLocator(probe: FakeProbe(files: [:], outputs: [:]))
        let found = locator.locate(in: env())
        #expect(found.chosen == nil)
        #expect(found.others.isEmpty && found.broken.isEmpty)
    }

    @Test func notExecutableAndSilentBinariesAreBroken() {
        let probe = FakeProbe(files: [
            sdkAdb: .notExecutable,
            "/opt/homebrew/bin/adb": .executable(realPath: "/opt/homebrew/bin/adb", modified: t0),
        ], outputs: ["/opt/homebrew/bin/adb": "not adb at all"])
        var locator = AdbLocator(probe: probe)
        let found = locator.locate(in: env())
        #expect(found.chosen == nil)
        #expect(found.broken.map(\.reason) == [.notExecutable, .noVersion])
    }

    @Test func versionIsReadOncePerModificationDate() {
        let unchanged = FakeProbe(files: [sdkAdb: .executable(realPath: sdkAdb, modified: t0)], outputs: [sdkAdb: versionText()])
        var locator = AdbLocator(probe: unchanged)
        _ = locator.locate(in: env())
        _ = locator.locate(in: env())
        #expect(unchanged.versionCalls.count == 1)
    }

    @Test func updatedBinaryIsReadAgain() {
        let probe = FakeProbe(files: [sdkAdb: .executable(realPath: sdkAdb, modified: t0)], outputs: [sdkAdb: versionText()])
        var locator = AdbLocator(probe: probe)
        #expect(locator.locate(in: env()).chosen?.version.release == "36.0.0")
        probe.replace(sdkAdb, with: .executable(realPath: sdkAdb, modified: t0 + 60), output: versionText("1.0.41", "37.0.0-1"))
        #expect(locator.locate(in: env()).chosen?.version.release == "37.0.0")
        #expect(probe.versionCalls == [sdkAdb, sdkAdb])
    }
}
