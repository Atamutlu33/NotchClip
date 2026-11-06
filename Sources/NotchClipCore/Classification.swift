import Foundation
import CryptoKit

/// Decides whether copied text is a plain link or ordinary text.
public enum ClipClassifier {
    /// A single web address with no surrounding text is a link; anything else is text.
    public static func kind(forText text: String) -> ClipKind {
        linkURL(from: text) == nil ? .text : .link
    }

    /// Returns the URL when the whole (trimmed) text is one http(s) address, or a bare `www.` address.
    public static func linkURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 4096,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }

        let lower = trimmed.lowercased()
        var candidate = trimmed
        if lower.hasPrefix("www.") {
            candidate = "https://" + trimmed
        } else if !(lower.hasPrefix("http://") || lower.hasPrefix("https://")) {
            return nil
        }
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              host.contains(".") || host == "localhost" else { return nil }
        return components.url
    }
}

/// Stable identities used to recognise the same content when it is copied again.
public enum ContentHash {
    public static func forText(_ text: String) -> String {
        "t:" + sha256(Data(text.utf8))
    }

    public static func forFiles(_ paths: [String]) -> String {
        "f:" + sha256(Data(paths.joined(separator: "\n").utf8))
    }

    public static func forImage(_ data: Data) -> String {
        "i:" + sha256(data)
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Small text helpers shared by the UI and search.
public enum ClipFormatting {
    /// Collapses all whitespace runs into single spaces and truncates with an ellipsis.
    public static func singleLine(_ text: String, limit: Int) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        guard collapsed.count > limit, limit > 1 else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// Lowercases and removes diacritics so "Çalışma" matches "calisma".
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }
}

public extension ClipFormatting {
    /// Compact age such as "now", "5m", "3h", "2d", "6w".
    static func shortAge(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "now"
        case ..<3_600: return "\(seconds / 60)m"
        case ..<86_400: return "\(seconds / 3_600)h"
        case ..<(86_400 * 14): return "\(seconds / 86_400)d"
        default: return "\(seconds / (86_400 * 7))w"
        }
    }

    /// Heuristic used to pick a monospaced font for previews.
    static func looksLikeCode(_ text: String) -> Bool {
        let sample = text.prefix(2_000)
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: false)
        let symbols = sample.filter { "{}[]();=<>$#/\\|&*".contains($0) }.count
        let indented = lines.filter { $0.hasPrefix("  ") || $0.hasPrefix("\t") }.count
        return symbols * 12 > sample.count || (lines.count >= 3 && indented * 3 >= lines.count)
    }
}
