import CoreGraphics
import Foundation
import HawkKit
import Testing

private let help = """
Usage: scrcpy [options]
    --always-on-top
    -b, --video-bit-rate=value
    --capture-orientation=value
    -m, --max-size=value
    --max-fps=value
    --no-audio
    --audio-source=source
    -n, --no-control
    --no-power-on
    -r, --record=file
    --no-window
    -t, --show-touches
    -w, --stay-awake
    -S, --turn-screen-off
    --video-codec=name
    --window-borderless
    --window-title=text
    --window-x=value
    --window-y=value
    --window-width=value
    --window-height=value
    -f, --fullscreen
"""

@Suite struct AndroidScrcpyTests {
    private let caps = ScrcpyCapabilities.parse(version: "scrcpy 5.0.1 <https://github.com/Genymobile/scrcpy>\n\nDependencies", help: help)

    @Test func capabilitiesFromHelp() {
        #expect(caps.version == "5.0.1")
        #expect(caps.supports("window-borderless") && caps.supports("max-size") && caps.supports("no-power-on"))
        #expect(!caps.supports("new-display") && !caps.supports("power-off-on-close"))
    }

    @Test func argumentsFromOptions() {
        var o = ScrcpyOptions()
        o.borderless = true
        o.alwaysOnTop = true
        o.maxSize = 1280
        o.bitrateMbps = 8
        o.codec = .h265
        o.audio = false
        o.viewOnly = true
        o.powerOffOnClose = true   // not supported by this help: left out
        let a = Scrcpy.arguments(o, serial: "FAKE0001", title: "Test phone", window: ScrcpyWindow(x: 10, y: 40, width: 400, height: 866),
                                 capabilities: caps, keepScreenAsIs: true)
        #expect(a == ["--serial=FAKE0001", "--window-title=Test phone", "--window-borderless", "--always-on-top",
                      "--window-x=10", "--window-y=40", "--window-width=400", "--window-height=866",
                      "--max-size=1280", "--video-bit-rate=8M", "--video-codec=h265", "--no-audio", "--no-control", "--no-power-on"])
    }

    @Test func fullscreenIgnoresTheWindowAndRecordOnlyHasNoWindow() {
        var o = ScrcpyOptions()
        o.fullscreen = true
        let a = Scrcpy.arguments(o, serial: "S", title: "T", window: ScrcpyWindow(x: 1, y: 2, width: 3, height: 4), capabilities: caps,
                                 record: URL(filePath: "/tmp/r.mp4"), recordOnly: true)
        #expect(a.contains("--fullscreen") && !a.contains { $0.hasPrefix("--window-x") })
        #expect(a.suffix(2) == ["--record=/tmp/r.mp4", "--no-window"])
    }

    @Test func contentAreaAndAspectRatio() {
        let content = ScrcpyWindow.content(ofFrame: CGRect(x: 100, y: 50, width: 400, height: 900), titleBar: 28)
        #expect(content == ScrcpyWindow(x: 100, y: 78, width: 400, height: 872))
        #expect(content.fitted(to: (1080, 2340)) == ScrcpyWindow(x: 100, y: 78, width: 400, height: 867))
        // Borderless: the frame is the content.
        #expect(ScrcpyWindow.content(ofFrame: CGRect(x: 0, y: 0, width: 300, height: 650), titleBar: 0).height == 650)
        // A screen to the left or above the main one has negative coordinates.
        #expect(ScrcpyWindow.content(ofFrame: CGRect(x: -1440, y: -300, width: 400, height: 900), titleBar: 28) ==
                ScrcpyWindow(x: -1440, y: -272, width: 400, height: 872))
    }

    @Test func tenRelaunchesDoNotDrift() {
        var w = ScrcpyWindow(x: 100, y: 78, width: 400, height: 872)
        for _ in 0..<10 {
            w = w.fitted(to: (1080, 2340))
            // scrcpy would report the same content back; the frame adds the title bar.
            w = ScrcpyWindow.content(ofFrame: CGRect(x: w.x, y: w.y - 28, width: w.width, height: w.height + 28), titleBar: 28)
        }
        #expect(w == ScrcpyWindow(x: 100, y: 78, width: 400, height: 867))
    }

    @Test func logParser() {
        let log = "INFO: scrcpy 5.0.1\nINFO: Renderer: metal\nINFO: Texture: 1080x2340\nERROR: Could not open video stream\nWARN: x\n"
        let parsed = Scrcpy.parseLog(log)
        #expect(parsed.texture?.width == 1080 && parsed.texture?.height == 2340)
        #expect(parsed.errors == ["ERROR: Could not open video stream"])
        #expect(Scrcpy.parseLog("INFO: Texture: 0x0\nTexture: abc").texture == nil)
    }
}

@Suite struct AndroidFFmpegTests {
    private let input = URL(filePath: "/tmp/in.mp4"), output = URL(filePath: "/tmp/out.mp4")

    @Test func presets() {
        let share = FFmpegPreset.share.arguments(input: input, output: output)
        #expect(share.contains("libx264") && share.contains("aac") && share.last == "/tmp/out.mp4")
        let small = FFmpegPreset.smallest.arguments(input: input, output: output)
        #expect(small.contains("hevc_videotoolbox") && small.contains("hvc1"))
        let gif = FFmpegPreset.gif.arguments(input: input, output: URL(filePath: "/tmp/out.gif"))
        #expect(gif.contains("-an") && gif.contains { $0.contains("palettegen") })
        #expect(FFmpegPreset.webp.fileExtension == "webp")
    }

    @Test func edits() {
        let a = FFmpegPreset.share.arguments(input: input, output: output, edits: .init(start: 2, end: 10, removeAudio: true, speed: 2))
        #expect(Array(a[3...8]) == ["-ss", "2.00", "-to", "10.00", "-i", "/tmp/in.mp4"])
        #expect(a.contains("-an") && !a.contains("aac") && a.contains { $0.hasPrefix("setpts=PTS/2.000") })
        let slow = FFmpegPreset.share.arguments(input: input, output: output, edits: .init(speed: 100))
        #expect(slow.contains { $0.hasPrefix("setpts=PTS/4.000") })
    }
}
