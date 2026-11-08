import Foundation

/// A video in the phone's media store (requirements 6.1).
public struct PhoneVideo: Sendable, Equatable, Identifiable {
    public let id: Int
    public let path: String
    public let size: Int64
    public let width: Int
    public let height: Int
    /// Milliseconds.
    public let duration: Int
    public let bitrate: Int?
    public let added: Date?
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var name: String { (path as NSString).lastPathComponent }
    public var longSide: Int { max(width, height) }

    public init(id: Int, path: String, size: Int64, width: Int, height: Int, duration: Int, bitrate: Int?, added: Date?) {
        self.id = id
        self.path = path
        self.size = size
        self.width = width
        self.height = height
        self.duration = duration
        self.bitrate = bitrate
        self.added = added
    }

    public static let query = "content query --uri content://media/external/video/media --projection _id:_data:_size:width:height:duration:bitrate:date_added --sort '_size DESC'"

    /// "Row: 0 _id=1, _data=/storage/emulated/0/DCIM/a.mp4, _size=..., ...": paths may
    /// hold ", " so fields are read by their known names.
    public static func parse(_ text: String) -> [PhoneVideo] {
        text.prefix(16 << 20).split(whereSeparator: \.isNewline).prefix(50_000).compactMap { line in
            guard line.hasPrefix("Row: ") else { return nil }
            func field(_ key: String, before next: String?) -> String? {
                guard let r = line.range(of: " \(key)=") else { return nil }
                let rest = line[r.upperBound...]
                if let next, let end = rest.range(of: ", \(next)=") { return String(rest[..<end.lowerBound]) }
                return String(rest)
            }
            guard let id = field("_id", before: "_data").flatMap(Int.init), let path = field("_data", before: "_size"),
                  ShellQuote.isRemotePath(path), let size = field("_size", before: "width").flatMap(Int64.init) else { return nil }
            return PhoneVideo(id: id, path: path, size: size,
                              width: field("width", before: "height").flatMap(Int.init) ?? 0,
                              height: field("height", before: "duration").flatMap(Int.init) ?? 0,
                              duration: field("duration", before: "bitrate").flatMap(Int.init) ?? 0,
                              bitrate: field("bitrate", before: "date_added").flatMap(Int.init),
                              added: field("date_added", before: nil).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) })
        }
    }
}

/// What the re-encode targets and what it would free, before anything is done.
public enum SaverEstimate {
    /// HEVC bitrates that look close to the original at each size (hardware encoder).
    public static func targetBitrate(longSide: Int) -> Int {
        switch longSide {
        case ..<1000: 1_500_000
        case ..<1500: 3_000_000
        case ..<2200: 6_000_000
        default: 14_000_000
        }
    }

    /// Size after re-encoding at `maxLongSide` (or the original size if smaller):
    /// video at the target bitrate plus 128 kb/s audio. Never more than the original.
    public static func estimate(_ v: PhoneVideo, maxLongSide: Int) -> Int64 {
        let side = min(v.longSide, maxLongSide)
        let bits = Double(targetBitrate(longSide: side) + 128_000) * Double(v.duration) / 1000
        return min(v.size, Int64(bits / 8))
    }

    public static func saving(_ videos: [PhoneVideo], maxLongSide: Int) -> Int64 {
        videos.reduce(0) { $0 + max(0, $1.size - estimate($1, maxLongSide: maxLongSide)) }
    }
}

/// The rules the storage saver obeys (requirements 6.1), checked at the moment of
/// acting: a file the check did not pass is never touched; WhatsApp media is never
/// touched; an original is deleted only when archived on the Mac or the user
/// confirmed losing it.
public enum SaverRules {
    public struct Check: Sendable, Equatable {
        public let duration: Int     // ms
        public let width: Int
        public let height: Int
        public let size: Int64
        public init(duration: Int, width: Int, height: Int, size: Int64) {
            self.duration = duration
            self.width = width
            self.height = height
            self.size = size
        }
    }

    public static func mayTouch(_ path: String) -> AndroidRules.Verdict {
        guard ShellQuote.isRemotePath(path), path.hasPrefix("/storage/emulated/") || path.hasPrefix("/sdcard/") else {
            return .blocked("Not in shared storage")
        }
        if path.localizedCaseInsensitiveContains("whatsapp") { return .blocked("WhatsApp media is never touched") }
        return AndroidRules.verdict(.deletePath(path), facts: DeviceFacts())
    }

    /// The new copy plays the same video: duration within 1 s, the expected
    /// resolution (scaled no larger than asked, same aspect), and a sane size.
    public static func verified(original v: PhoneVideo, copy c: Check, maxLongSide: Int) -> Bool {
        guard c.size > 0, c.size < v.size else { return false }
        guard abs(c.duration - v.duration) <= 1000 else { return false }
        let expected = min(v.longSide, maxLongSide)
        guard abs(max(c.width, c.height) - expected) <= 2 else { return false }
        guard v.width > 0, v.height > 0, c.width > 0, c.height > 0 else { return false }
        let a = Double(v.width) / Double(v.height), b = Double(c.width) / Double(c.height)
        return abs(a - b) < 0.02
    }

    /// Deleting the original on the phone: only after the rules, and only when it is
    /// archived (its copy on the Mac has the same size) or the user confirmed it.
    public static func mayDeleteOriginal(_ v: PhoneVideo, archivedSize: Int64?, userConfirmedLoss: Bool, copyVerified: Bool) -> AndroidRules.Verdict {
        if case .blocked(let why) = mayTouch(v.path) { return .blocked(why) }
        guard copyVerified || userConfirmedLoss else { return .blocked("The new copy did not pass the check") }
        if archivedSize == v.size || userConfirmedLoss { return .allowed }
        return .blocked("Not archived on the Mac, and losing it was not confirmed")
    }
}
