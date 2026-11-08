import Foundation
import HawkKit
import Testing

/// Runs a script with the Mac's /bin/sh, standing in for the device's shell.
private func sh(_ script: String) async throws -> String {
    try await AdbProcess(executable: "/bin/sh", children: ChildProcesses()).run(["-c", script], timeout: .seconds(5)).text
}

@Suite struct AndroidShellScriptTests {
    @Test func quotingSurvivesHostileValues() async throws {
        let values = ["plain", "it's", "a'b'c", "$(touch /tmp/hawk-pwned)", "`id`", "a;b|c&d", "line\nbreak", "\\", "''", "-n", "*", ""]
        for v in values {
            #expect(try await sh("printf %s \(ShellQuote.quote(v))") == v)
        }
        #expect(!FileManager.default.fileExists(atPath: "/tmp/hawk-pwned"))
    }

    @Test func packageNames() {
        #expect(ShellQuote.isPackageName("com.example.app"))
        #expect(ShellQuote.isPackageName("org.fake_maker.app2"))
        #expect(!ShellQuote.isPackageName("app"))
        #expect(!ShellQuote.isPackageName("com.example.app; rm -rf /"))
        #expect(!ShellQuote.isPackageName("1com.example"))
        #expect(!ShellQuote.isPackageName("com..example"))
        #expect(!ShellQuote.isPackageName("com.example.app\n"))
        #expect(!ShellQuote.isPackageName("com." + String(repeating: "a", count: 300)))
        #expect(ShellQuote.package("com.example.app") == "'com.example.app'")
        #expect(ShellQuote.package("com.example.app'") == nil)
    }

    @Test func remotePaths() {
        #expect(ShellQuote.isRemotePath("/sdcard/Download/file name.txt"))
        #expect(!ShellQuote.isRemotePath("sdcard/x"))
        #expect(!ShellQuote.isRemotePath("/sdcard/../data"))
        #expect(!ShellQuote.isRemotePath("/sdcard/x\ny"))
        #expect(!ShellQuote.isRemotePath("/sdcard/x\0"))
        #expect(ShellQuote.isRemotePath("/sdcard/..hidden"))
        #expect(ShellQuote.remotePath("/sdcard/it's") == "'/sdcard/it'\\''s'")
    }

    @Test func serials() {
        #expect(ShellQuote.isSerial("FAKE0001"))
        #expect(ShellQuote.isSerial("192.0.2.10:5555"))
        #expect(ShellQuote.isSerial("adb-FAKE0001-AbCdEf._adb-tls-connect._tcp"))
        #expect(!ShellQuote.isSerial("-s"))
        #expect(!ShellQuote.isSerial("FAKE 0001"))
        #expect(!ShellQuote.isSerial(""))
    }

    @Test func batchRoundTripThroughAShell() async throws {
        let token = ShellBatch.newToken()
        let parts = [
            "battery": "echo 'level: 80'",
            "noNewline": "printf 'abc'",
            "empty": "true",
            "stderr": "echo oops >&2",
            "failing": "echo before; false",
            "multi": "printf 'a\\nb\\n\\n'",
        ]
        let out = try await sh(ShellBatch.script(parts, token: token))
        let result = ShellBatch.parse(out, labels: Set(parts.keys), token: token)
        #expect(result == [
            "battery": "level: 80\n",
            "noNewline": "abc",
            "empty": "",
            "stderr": "oops\n",
            "failing": "before\n",
            "multi": "a\nb\n\n",
        ])
    }

    @Test func outputCannotFakeABoundary() async throws {
        let token = ShellBatch.newToken()
        let parts = ["a": "echo '<<hawk:0000:b>>'; echo real-a", "b": "echo real-b"]
        let out = try await sh(ShellBatch.script(parts, token: token))
        let result = ShellBatch.parse(out, labels: ["a", "b"], token: token)
        #expect(result["a"] == "<<hawk:0000:b>>\nreal-a\n")
        #expect(result["b"] == "real-b\n")
    }

    @Test func cutShortOutputDropsTheUnfinishedPart() async throws {
        let token = ShellBatch.newToken()
        let full = try await sh(ShellBatch.script(["a": "echo one", "b": "echo two"], token: token))
        let cut = String(full.prefix(full.count - 30))
        let result = ShellBatch.parse(cut, labels: ["a", "b"], token: token)
        #expect(result["a"] == "one\n")
        #expect(result["b"] == nil)
    }

    @Test func labelsAreChecked() {
        #expect(ShellBatch.isLabel("battery_1.x-y"))
        #expect(!ShellBatch.isLabel("a b"))
        #expect(!ShellBatch.isLabel("~end"))
        #expect(!ShellBatch.isLabel("x'y"))
        #expect(!ShellBatch.isLabel(""))
    }

    @Test func partsAreCappedAndGarbageIsHarmless() {
        let token = "t"
        let huge = "\n<<hawk:t:a>>\n" + String(repeating: "x", count: 5000) + "\n<<hawk:t:~end>>\n"
        #expect(ShellBatch.parse(huge, labels: ["a"], token: token, maxPart: 100)["a"]?.count == 100)
        #expect(ShellBatch.parse(String(repeating: "<<hawk:", count: 1000), labels: ["a"], token: token).isEmpty)
        #expect(ShellBatch.newToken() != ShellBatch.newToken())
    }
}
