import Foundation
import SQLite3

/// WhatsApp media per chat. Strictly read-only: it lists folders, reads file sizes and
/// opens WhatsApp's chat database with SQLITE_OPEN_READONLY for names and last-message
/// dates. Nothing in Hawk deletes WhatsApp data (see StorageRules.protectedPrefixes).
///
/// A full walk is ~60k files. Results are cached per chat with a signature (the newest
/// mtime among the chat's folders, where new media lands), so a refresh re-walks only
/// the chats that changed.
public struct WhatsAppChat: Codable, Sendable, Identifiable {
    public let jid: String
    public var name: String?
    public var bytes: Int64
    public var files: Int
    public var byKind: [String: Int64]
    public var signature: Date?
    public var lastMessage: Date?
    public var id: String { jid }
    public var displayName: String { (name?.isEmpty == false ? name : nil) ?? jid.components(separatedBy: "@").first ?? jid }
}

public struct WhatsAppReport: Codable, Sendable {
    public var chats: [WhatsAppChat]
    public var measuredAt: Date
    public var rewalked: Int
    public var totalBytes: Int64 { chats.map(\.bytes).reduce(0, +) }
    public func bytes(ofKind kind: String) -> Int64 { chats.map { $0.byKind[kind] ?? 0 }.reduce(0, +) }
}

public final class WhatsAppAnalyzer {
    public static let container = StorageRules.expand("~/Library/Group Containers/group.net.whatsapp.WhatsApp.shared")
    public static let kinds = ["Videos", "Photos", "Audio", "Documents", "Other"]
    private let cacheURL: URL

    public init(cacheURL: URL) { self.cacheURL = cacheURL }

    public var isInstalled: Bool { FileManager.default.fileExists(atPath: Self.container + "/Message/Media") }

    /// The cached report, if any, without touching WhatsApp's folders.
    public func cached() -> WhatsAppReport? {
        (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(WhatsAppReport.self, from: $0) }
    }

    public enum Failure: Error { case noAccess }

    /// nil when WhatsApp is not installed; throws when macOS hides its folders from Hawk
    /// (no Full Disk Access): an empty listing would otherwise read as "no media".
    public func analyze() throws -> WhatsAppReport? {
        guard isInstalled else { return nil }
        let media = URL(filePath: Self.container + "/Message/Media")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: media, includingPropertiesForKeys: [.isDirectoryKey]),
              !folders.isEmpty else { throw Failure.noAccess }
        let previous = Dictionary((cached()?.chats ?? []).map { ($0.jid, $0) }, uniquingKeysWith: { a, _ in a })
        let sessions = Self.sessions()
        var rewalked = 0
        let chats = folders.compactMap { folder -> WhatsAppChat? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let jid = folder.lastPathComponent
            let signature = Self.signature(folder)
            var chat: WhatsAppChat
            if let old = previous[jid], old.signature == signature {
                chat = old
            } else {
                chat = Self.walk(folder, jid: jid, signature: signature)
                rewalked += 1
            }
            chat.name = sessions[jid]?.name
            chat.lastMessage = sessions[jid]?.last
            return chat
        }
        let report = WhatsAppReport(chats: chats.sorted { $0.bytes > $1.bytes }, measuredAt: Date(), rewalked: rewalked)
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(report).write(to: cacheURL, options: .atomic)
        } catch {
            Log.app.warning("Could not cache the WhatsApp report: \(error.localizedDescription)")
        }
        return report
    }

    /// Newest mtime of the chat folder and its folders two levels down, where files land.
    static func signature(_ folder: URL) -> Date? {
        let fm = FileManager.default
        func mtime(_ u: URL) -> Date? { (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
        var newest = mtime(folder)
        for level1 in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let d = mtime(level1), d > (newest ?? .distantPast) { newest = d }
            for level2 in (try? fm.contentsOfDirectory(at: level1, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                if let d = mtime(level2), d > (newest ?? .distantPast) { newest = d }
            }
        }
        return newest
    }

    static func walk(_ folder: URL, jid: String, signature: Date?) -> WhatsAppChat {
        var chat = WhatsAppChat(jid: jid, bytes: 0, files: 0, byKind: [:], signature: signature)
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
        while let item = e?.nextObject() as? URL {
            guard let v = try? item.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? 0)
            chat.bytes += size
            chat.files += 1
            chat.byKind[kind(item.pathExtension.lowercased()), default: 0] += size
        }
        return chat
    }

    static func kind(_ ext: String) -> String {
        switch ext {
        case "mp4", "mov", "m4v", "3gp", "webm", "mkv": "Videos"
        case "jpg", "jpeg", "png", "webp", "heic", "gif", "thumb": "Photos"
        case "opus", "m4a", "mp3", "ogg", "aac", "wav", "caf": "Audio"
        case "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "zip", "txt", "csv", "rar", "apk": "Documents"
        default: "Other"
        }
    }

    /// Chat names and last message dates, read-only from WhatsApp's database.
    static func sessions() -> [String: (name: String?, last: Date?)] {
        var db: OpaquePointer?
        let path = "file:" + container + "/ChatStorage.sqlite?mode=ro"
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZCONTACTJID, ZPARTNERNAME, ZLASTMESSAGEDATE FROM ZWACHATSESSION", -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var out: [String: (String?, Date?)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let jid = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
            let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let last = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
            out[jid] = (name, last)
        }
        return out
    }
}
