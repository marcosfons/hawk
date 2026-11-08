import Foundation
import HawkKit
import Testing

@Suite struct AndroidPackageIndexTests {
    private let all = """
    package:android versionCode:35 uid:1000
    package:com.android.settings versionCode:35 uid:1000
    package:com.example.game versionCode:128 uid:10414
    package:com.example.chat versionCode:22425 uid:10449,1010449
    package:com.example.bad;reboot versionCode:1 uid:10500
    Error: java.lang.SecurityException: Shell does not have permission to access user 150
    garbage
    """
    private let user = "package:com.example.game\npackage:com.example.chat\n"

    @Test func parsesPackagesUidsAndKinds() {
        let index = PackageIndex.parse(["all": all, "user": user])
        #expect(index.packages.count == 4)
        #expect(index["com.example.game"] == PackageInfo(name: "com.example.game", uid: 10414, versionCode: 128, isSystem: false))
        #expect(index["com.example.chat"]?.uid == 10449)
        #expect(index["com.android.settings"]?.isSystem == true)
        #expect(index["android"]?.isSystem == true)
        #expect(index["com.example.bad;reboot"] == nil)
    }

    @Test func sharedUidsListEveryPackage() {
        let index = PackageIndex.parse(["all": all, "user": user])
        #expect(index.packages(uid: 1000) == ["android", "com.android.settings"])
        #expect(index.packages(uid: 99999).isEmpty)
    }

    @Test func truncatedAndHugeOutputIsSafe() {
        let cut = PackageIndex.parse(["all": "package:com.example.game versionCode:12", "user": ""])
        #expect(cut["com.example.game"]?.uid == nil && cut["com.example.game"]?.versionCode == 12)
        let many = (0..<20_000).map { "package:com.example.p\($0) versionCode:1 uid:\(10000 + $0)" }.joined(separator: "\n")
        #expect(PackageIndex.parse(["all": many]).packages.count == PackageIndex.maxPackages)
        #expect(PackageIndex.parse([:]).packages.isEmpty)
    }

    @Test func labelsAreCapped() {
        var index = PackageIndex.parse(["all": all, "user": user])
        index.setLabel(String(repeating: "x", count: 500), for: "com.example.game")
        #expect(index["com.example.game"]?.label?.count == 128)
        index.setLabel("Ignored", for: "com.example.missing")
        #expect(index["com.example.missing"] == nil)
    }

    @Test func roundTripsThroughJSON() throws {
        let index = PackageIndex.parse(["all": all, "user": user], date: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(try JSONDecoder().decode(PackageIndex.self, from: JSONEncoder().encode(index)) == index)
    }
}
