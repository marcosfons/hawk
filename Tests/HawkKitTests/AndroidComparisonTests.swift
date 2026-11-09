import Foundation
import HawkKit
import Testing

@Suite struct AndroidComparisonTests {
    private func apps(_ json: String) throws -> [AppEntry] {
        try JSONDecoder().decode([AppEntry].self, from: Data(json.utf8))
    }

    @Test func appsAreSortedByWhatDiffers() throws {
        let a = try apps("""
        [{"name":"com.example.same","label":"Same","versionCode":3,"versionName":"1.2","isSystem":false,"enabled":true},
         {"name":"com.example.newer","label":"Newer","versionCode":10,"versionName":"2.0","isSystem":false,"enabled":true},
         {"name":"com.example.onlya","label":"Only A","versionCode":1,"isSystem":false,"enabled":true},
         {"name":"com.example.system","label":"Sys","versionCode":1,"isSystem":true,"enabled":true}]
        """)
        let b = try apps("""
        [{"name":"com.example.same","label":"Same","versionCode":3,"versionName":"1.2","isSystem":false,"enabled":true},
         {"name":"com.example.newer","label":"Newer","versionCode":9,"versionName":"1.9","isSystem":false,"enabled":true},
         {"name":"com.example.onlyb","versionName":"5","isSystem":false,"enabled":true},
         {"name":"com.example.system","label":"Sys","versionCode":2,"isSystem":true,"enabled":true}]
        """)
        let rows = DeviceComparison.apps(a, b, includeSystem: false)
        #expect(rows.map(\.name) == ["com.example.newer", "com.example.onlya", "com.example.onlyb", "com.example.same"])
        #expect(rows.map(\.kind) == [.differs, .onlyA, .onlyB, .same])
        #expect(rows[0].a == "2.0 (10)" && rows[0].b == "1.9 (9)")
        #expect(rows[1].b == nil && rows[2].a == nil)
        #expect(rows[2].label == "com.example.onlyb" && rows[2].b == "5")

        let all = DeviceComparison.apps(a, b, includeSystem: true)
        #expect(all.first { $0.name == "com.example.system" }?.kind == .differs)
    }

    @Test func versionNamesDecideWhenCodesAreMissing() throws {
        let a = try apps(#"[{"name":"com.example.x","versionName":"1.0","isSystem":false,"enabled":true}]"#)
        let b = try apps(#"[{"name":"com.example.x","versionName":"1.1","isSystem":false,"enabled":true}]"#)
        #expect(DeviceComparison.apps(a, b, includeSystem: false).first?.kind == .differs)
        #expect(DeviceComparison.apps(a, a, includeSystem: false).first?.kind == .same)
    }

    @Test func systemRowsMarkDifferencesAndMissingSides() {
        var a = SystemInfo()
        a.props = ["ro.product.model": "Test One", "ro.build.version.release": "14", "ro.build.version.sdk": "34"]
        a.ramKB = 8 * 1024 * 1024
        var b = a
        b.props["ro.build.version.release"] = "15"
        b.props["ro.build.version.sdk"] = "35"
        let rows = DeviceComparison.system(a, b)
        #expect(rows.first { $0.label == "Model" }?.differs == false)
        #expect(rows.first { $0.label == "Android" }.map { ($0.a, $0.b) } ?? ("", "") == ("14 (SDK 34)", "15 (SDK 35)"))
        let missing = DeviceComparison.system(a, nil)
        #expect(missing.first { $0.label == "Model" }?.b == "-")
    }

    @Test func settingsShowOnlyDifferences() {
        let a = DeviceComparison.parseSettings("[global]\nadb_enabled=1\nstay_on_while_plugged_in=0\n[system]\nscreen_brightness=100\n")
        let b = DeviceComparison.parseSettings("[global]\nadb_enabled=1\nstay_on_while_plugged_in=7\n[system]\nfont_scale=1.1\n")
        let rows = DeviceComparison.settings(a, b)
        #expect(rows.map(\.label) == ["global/stay_on_while_plugged_in", "system/font_scale", "system/screen_brightness"])
        #expect(rows[1].a == "-" && rows[1].b == "1.1")
    }

    @Test func settingsParserSurvivesGarbage() {
        #expect(DeviceComparison.parseSettings("key=before any table\n=no key\n\u{0}\u{1}").isEmpty)
        let long = DeviceComparison.parseSettings("[global]\n" + String(repeating: "k", count: 500) + "=" + String(repeating: "v", count: 5000))
        #expect(long.count == 1 && long.values.first?.count == 200 && long.keys.first!.count == "global/".count + 120)
        let many = DeviceComparison.parseSettings("[system]\n" + (0..<20_000).map { "k\($0)=v" }.joined(separator: "\n"))
        #expect(many.count < 5000)
    }
}
