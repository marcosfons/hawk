import CoreGraphics
import Foundation

/// What a scrcpy session is launched with (requirements 10.1). Options are fixed at
/// launch: changing one means relaunching in place.
public struct ScrcpyOptions: Sendable, Equatable, Codable {
    public enum Codec: String, Sendable, Codable, CaseIterable { case h264, h265, av1 }
    public enum AudioSource: String, Sendable, Codable, CaseIterable { case output, mic }

    // Window
    public var borderless = false
    public var alwaysOnTop = false
    public var fullscreen = false
    // Video
    /// Longest side in pixels; nil keeps the device's own.
    public var maxSize: Int?
    public var maxFps: Int?
    public var bitrateMbps: Int?
    public var codec: Codec?
    public var displayID: Int?
    public var lockOrientation = false
    // Audio
    public var audio = true
    public var audioSource: AudioSource = .output
    // Control
    public var viewOnly = false
    public var showTouches = false
    public var stayAwake = false
    public var turnScreenOff = false
    public var powerOffOnClose = false

    public init() {}

    /// Options whose change needs a new session (all of them except none: scrcpy has
    /// no control channel), and which are therefore locked while recording.
    public func needsRelaunch(from other: ScrcpyOptions) -> Bool { self != other }
}

/// What the installed scrcpy supports, from its own `--version` and `--help`.
public struct ScrcpyCapabilities: Sendable, Equatable {
    public let version: String?
    public let options: Set<String>

    public init(version: String?, options: Set<String>) {
        self.version = version
        self.options = options
    }

    /// "scrcpy 5.0.1 <https://...>"; every "--long-option" the help mentions.
    public static func parse(version: String, help: String) -> ScrcpyCapabilities {
        let v = version.split(whereSeparator: \.isNewline).first.flatMap { line -> String? in
            let words = line.split(separator: " ")
            return words.count >= 2 && words[0] == "scrcpy" ? String(words[1].prefix(16)) : nil
        }
        var options = Set<String>()
        for match in help.prefix(256 * 1024).matches(of: /--([a-z0-9][a-z0-9-]{1,40})/) {
            options.insert(String(match.1))
        }
        return ScrcpyCapabilities(version: v, options: options)
    }

    public func supports(_ option: String) -> Bool { options.contains(option) }
}

/// A window's content area in screen points, top-left origin (what scrcpy's
/// --window-x/-y/-width/-height mean, and what CGWindowList reports frames in).
public struct ScrcpyWindow: Sendable, Equatable, Codable {
    public var x: Int, y: Int, width: Int, height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The content area of a window frame: below the title bar (zero when borderless).
    public static func content(ofFrame frame: CGRect, titleBar: CGFloat) -> ScrcpyWindow {
        ScrcpyWindow(x: Int(frame.minX.rounded()), y: Int((frame.minY + titleBar).rounded()),
                     width: Int(frame.width.rounded()), height: Int((frame.height - titleBar).rounded()))
    }

    /// Same top-left and width, height from the video's aspect ratio: scrcpy shrinks
    /// a box to the video and centres it, so passing the frame back would drift.
    public func fitted(to texture: (width: Int, height: Int)?) -> ScrcpyWindow {
        guard let t = texture, t.width > 0, t.height > 0, width > 0 else { return self }
        return ScrcpyWindow(x: x, y: y, width: width, height: max(1, Int((Double(width) * Double(t.height) / Double(t.width)).rounded())))
    }
}

public enum Scrcpy {
    /// The scrcpy to run: Homebrew's, then /usr/local, then PATH.
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let candidates = ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy"]
            + (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/scrcpy" }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The arguments for a session; options the installed version lacks are left out.
    public static func arguments(_ o: ScrcpyOptions, serial: String, title: String, window: ScrcpyWindow?,
                                 capabilities c: ScrcpyCapabilities, record: URL? = nil, recordOnly: Bool = false,
                                 keepScreenAsIs: Bool = false) -> [String] {
        var a = ["--serial=\(serial)"]
        func add(_ option: String, _ value: String? = nil) {
            guard c.supports(option) else { return }
            a.append(value.map { "--\(option)=\($0)" } ?? "--\(option)")
        }
        add("window-title", String(title.prefix(80)))
        if o.borderless { add("window-borderless") }
        if o.alwaysOnTop { add("always-on-top") }
        if o.fullscreen { add("fullscreen") }
        if let w = window, !o.fullscreen, w.width > 0, w.height > 0 {
            add("window-x", String(w.x)); add("window-y", String(w.y))
            add("window-width", String(w.width)); add("window-height", String(w.height))
        }
        if let m = o.maxSize, m > 0 { add("max-size", String(m)) }
        if let f = o.maxFps, f > 0 { add("max-fps", String(f)) }
        if let b = o.bitrateMbps, b > 0 { add("video-bit-rate", "\(b)M") }
        if let codec = o.codec { add("video-codec", codec.rawValue) }
        if let d = o.displayID { add("display-id", String(d)) }
        if o.lockOrientation { add("capture-orientation", "@") }
        if !o.audio { add("no-audio") } else if o.audioSource == .mic { add("audio-source", "mic") }
        if o.viewOnly { add("no-control") }
        if o.showTouches { add("show-touches") }
        if o.stayAwake { add("stay-awake") }
        if o.turnScreenOff { add("turn-screen-off") }
        if o.powerOffOnClose { add("power-off-on-close") }
        // A relaunch leaves the phone's screen as it was.
        if keepScreenAsIs { add("no-power-on") }
        if let record { add("record", record.path) }
        if recordOnly { add("no-window") }
        return a
    }

    /// scrcpy's own log: the video size ("INFO: Texture: 1080x2340") and errors.
    public static func parseLog(_ text: String) -> (texture: (width: Int, height: Int)?, errors: [String]) {
        var texture: (Int, Int)?
        var errors: [String] = []
        for line in text.prefix(256 * 1024).split(whereSeparator: \.isNewline).prefix(5000) {
            if let r = line.range(of: "Texture: ") {
                let dims = line[r.upperBound...].prefix { $0.isNumber || $0 == "x" }.split(separator: "x")
                if dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]), w > 0, h > 0 { texture = (w, h) }
            } else if line.hasPrefix("ERROR:") || line.hasPrefix("FATAL:") {
                if errors.count < 20 { errors.append(String(line.prefix(300))) }
            }
        }
        return (texture, errors)
    }
}

/// ffmpeg presets for captures (requirements 10.2). The original is never touched.
public enum FFmpegPreset: String, Sendable, CaseIterable {
    case share, smallest, gif, webp

    public var title: String {
        switch self {
        case .share: "Share (H.264, 1080p)"
        case .smallest: "Smallest (HEVC, 720p)"
        case .gif: "GIF (15 fps, 480 px)"
        case .webp: "WebP (15 fps, 480 px)"
        }
    }

    public var fileExtension: String { self == .gif ? "gif" : self == .webp ? "webp" : "mp4" }

    /// Trim to `start`...`end` seconds, drop audio, speed up by `speed`.
    public struct Edits: Sendable, Equatable {
        public var start: Double?
        public var end: Double?
        public var removeAudio = false
        public var speed: Double = 1
        public init(start: Double? = nil, end: Double? = nil, removeAudio: Bool = false, speed: Double = 1) {
            self.start = start
            self.end = end
            self.removeAudio = removeAudio
            self.speed = speed
        }
    }

    public func arguments(input: URL, output: URL, edits: Edits = Edits()) -> [String] {
        var a = ["-hide_banner", "-nostdin", "-y"]
        if let s = edits.start, s > 0 { a += ["-ss", String(format: "%.2f", s)] }
        if let e = edits.end, e > (edits.start ?? 0) { a += ["-to", String(format: "%.2f", e)] }
        a += ["-i", input.path]
        let speed = min(max(edits.speed, 0.25), 4)
        let pts = speed != 1 ? String(format: "setpts=PTS/%.3f,", speed) : ""
        switch self {
        case .share:
            a += ["-vf", pts + "scale=-2:'min(1080,ih)'", "-c:v", "libx264", "-crf", "23", "-preset", "medium", "-pix_fmt", "yuv420p", "-movflags", "+faststart"]
        case .smallest:
            a += ["-vf", pts + "scale=-2:'min(720,ih)'", "-c:v", "hevc_videotoolbox", "-b:v", "2M", "-tag:v", "hvc1", "-movflags", "+faststart"]
        case .gif:
            a += ["-vf", pts + "fps=15,scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse", "-loop", "0"]
        case .webp:
            a += ["-vf", pts + "fps=15,scale=480:-1", "-c:v", "libwebp", "-q:v", "60", "-loop", "0"]
        }
        if self == .gif || self == .webp || edits.removeAudio {
            a.append("-an")
        } else {
            a += ["-c:a", "aac", "-b:a", "128k"]
            if speed != 1 { a += ["-af", String(format: "atempo=%.3f", min(max(speed, 0.5), 2))] }
        }
        a.append(output.path)
        return a
    }
}
