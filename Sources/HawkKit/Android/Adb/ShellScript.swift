import Foundation

/// The one way values get into an `adb shell` script: validated for what they claim
/// to be, then single-quoted. Every plan builds scripts through this.
public enum ShellQuote {
    /// `'it'\''s'`: safe for any string without NUL, whatever it contains.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `com.example.app`: letters, digits and underscores, two segments or more.
    public static func isPackageName(_ s: String) -> Bool {
        guard s.count <= 255 else { return false }
        return s.wholeMatch(of: /[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z0-9_]+)+/) != nil
    }

    /// An absolute path on the device: no NUL or newline, no `..` component, capped.
    public static func isRemotePath(_ s: String) -> Bool {
        guard s.hasPrefix("/"), s.count <= 1024, !s.contains("\0"), !s.contains(where: \.isNewline) else { return false }
        return !s.split(separator: "/").contains("..")
    }

    /// An adb serial as `-s` takes it: printable ASCII, no spaces, not an option.
    public static func isSerial(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 256 && !s.hasPrefix("-") && s.allSatisfy { $0.isASCII && $0.asciiValue.map { $0 > 0x20 && $0 < 0x7F } == true }
    }

    /// The quoted value, or nil when it is not a valid package name.
    public static func package(_ s: String) -> String? { isPackageName(s) ? quote(s) : nil }

    /// The quoted value, or nil when it is not a valid remote path.
    public static func remotePath(_ s: String) -> String? { isRemotePath(s) ? quote(s) : nil }
}

/// Several labelled commands in one `adb shell` call: one process and one round trip
/// for everything a page reads each tick. Outputs are split at marker lines carrying
/// a random token, so a command's own output cannot fake a boundary.
public enum ShellBatch {
    /// Labels name the parts in the result: short, plain.
    public static func isLabel(_ s: String) -> Bool {
        s.wholeMatch(of: /[A-Za-z0-9_.\-]{1,64}/) != nil
    }

    /// Each part's stdout and stderr, in label order, between markers; each part in a
    /// subshell, so an `exit` or `cd` in one cannot cut the others short. A marker starts
    /// with a newline so output without a final newline cannot hide it; that newline
    /// is taken off again when parsing, so each part reads exactly as printed.
    public static func script(_ parts: [String: String], token: String) -> String {
        parts.keys.sorted().map { label in
            "printf '\\n%s\\n' '\(marker(token, label))'; ( \(parts[label] ?? ":")\n) 2>&1"
        }.joined(separator: "; ") + "; printf '\\n%s\\n' '\(marker(token, "~end"))'"
    }

    /// Splits the output back into parts. A part that never printed its marker (the
    /// call was cut short) is missing from the result; each part is capped.
    public static func parse(_ output: String, labels: Set<String>, token: String, maxPart: Int = 1 << 20) -> [String: String] {
        var result: [String: String] = [:]
        var current: String?
        var lines: [Substring] = []
        func flush() {
            guard let label = current else { return }
            var text = lines.joined(separator: "\n")
            if text.count > maxPart { text = String(text.prefix(maxPart)) }
            result[label] = text
        }
        let prefix = "<<hawk:\(token):"
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
            if trimmed.hasPrefix(prefix), trimmed.hasSuffix(">>") {
                flush()
                lines = []
                let label = String(trimmed.dropFirst(prefix.count).dropLast(2))
                current = labels.contains(label) ? label : nil
                continue
            }
            if current != nil { lines.append(trimmed) }
        }
        // Without the end marker the last part may be cut off: it is left out.
        return result
    }

    /// A fresh unguessable token for one call.
    public static func newToken() -> String {
        (0..<4).map { _ in String(format: "%08x", UInt32.random(in: .min ... .max)) }.joined()
    }

    static func marker(_ token: String, _ label: String) -> String { "<<hawk:\(token):\(label)>>" }
}
