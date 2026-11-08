import HawkKit
import Testing

@Suite struct AndroidDevToolsTests {
    @Test func togglesReadAndWrite() throws {
        let anim = try #require(DevToggle.all.first { $0.id == "animations" })
        #expect(anim.read == "settings get global animator_duration_scale")
        #expect(anim.write("0.0") == "settings put global animator_duration_scale 0.0")
        #expect(anim.write("null") == "settings delete global animator_duration_scale")
        #expect(anim.write("1; reboot") == nil)
        #expect(anim.isOn(anim.value(from: "0\n")) && !anim.isOn(anim.value(from: "null")))
        let dark = try #require(DevToggle.all.first { $0.id == "dark" })
        #expect(dark.value(from: "Night mode: yes\n") == "yes" && dark.isOn("yes"))
        #expect(dark.write("no") == "cmd uimode night no")
    }

    @Test func deepLinksAndText() {
        #expect(DevCommands.open("https://example.com/a?b=c d") == "am start -a android.intent.action.VIEW -d 'https://example.com/a?b=c d'")
        #expect(DevCommands.open("myapp://x", package: "com.example.app") == "am start -a android.intent.action.VIEW -d 'myapp://x' 'com.example.app'")
        #expect(DevCommands.open("no scheme") == nil)
        #expect(DevCommands.open("a://b\nreboot") == nil)
        #expect(DevCommands.type("hello world's 100%") == "input text 'hello%sworld'\\''s%s100\\%'")
        #expect(DevCommands.type("") == nil)
    }

    @Test func vmServiceUrl() {
        let found = DevCommands.vmService("http://127.0.0.1:43123/AbCd=/\n")
        #expect(found?.port == 43123 && found?.path == "/AbCd=/")
        #expect(DevCommands.vmService("http://10.0.0.1:1/x") == nil)
        #expect(DevCommands.vmService("") == nil)
    }
}
