import Foundation

/// Whether and how a device is managed (requirements 2.2): device owner, profile
/// owners per user, and the users and profiles on it (a work profile, Samsung's
/// Secure Folder, which is a profile with its own owner).
public struct Management: Sendable, Equatable, Codable {
    public struct User: Sendable, Equatable, Codable {
        public let id: Int
        public let name: String
        public let running: Bool
        /// FLAG_MANAGED_PROFILE (0x20) or a profile owner: a work or secure profile.
        public var managedProfile: Bool
    }

    public var deviceOwner: String?
    /// User id -> owner package.
    public var profileOwners: [Int: String] = [:]
    public var users: [User] = []

    public init() {}

    public var isManaged: Bool { deviceOwner != nil || !profileOwners.isEmpty }

    public static let parts: [String: String] = [
        "owners": "dpm list-owners 2>&1",
        "users": "pm list users 2>&1",
    ]

    public static func parse(_ p: [String: String]) -> Management {
        var m = Management()
        for line in (p["owners"] ?? "").prefix(64 * 1024).split(whereSeparator: \.isNewline) {
            // "User 150: admin=com.example.agent/.Receiver,ProfileOwner"
            guard line.hasPrefix("User "), let colon = line.firstIndex(of: ":"), let user = Int(line.dropFirst(5)[..<colon]),
                  let r = line.range(of: "admin=") else { continue }
            guard let pkg = line[r.upperBound...].split(separator: "/").first.map(String.init), ShellQuote.isPackageName(pkg) else { continue }
            if line.contains("DeviceOwner") { m.deviceOwner = pkg }
            if line.contains("ProfileOwner") { m.profileOwners[user] = pkg }
        }
        for line in (p["users"] ?? "").prefix(64 * 1024).split(whereSeparator: \.isNewline).prefix(64) {
            // "UserInfo{150:Secure Folder:61010} running"
            guard let open = line.range(of: "UserInfo{"), let close = line.range(of: "}", range: open.upperBound..<line.endIndex) else { continue }
            let fields = line[open.upperBound..<close.lowerBound].split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 3, let id = Int(fields[0]) else { continue }
            let flags = Int(fields[fields.count - 1], radix: 16) ?? 0
            let name = fields[1..<(fields.count - 1)].joined(separator: ":")
            m.users.append(User(id: id, name: String(name.prefix(64)), running: line.contains("running"),
                                managedProfile: flags & 0x20 != 0 || m.profileOwners[id] != nil))
        }
        return m
    }
}
