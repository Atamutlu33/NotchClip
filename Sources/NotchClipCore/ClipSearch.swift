import Foundation

/// The tabs at the top of the shelf.
public enum ClipFilter: String, CaseIterable, Identifiable, Sendable {
    case all, text, links, images, files, pinned

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .files: return "Files"
        case .pinned: return "Pinned"
        }
    }

    public func accepts(_ item: ClipItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.kind == .text
        case .links: return item.kind == .link
        case .images: return item.kind == .image
        case .files: return item.kind == .file
        case .pinned: return item.isPinned
        }
    }

    /// The next tab, wrapping around.
    public func next(by step: Int = 1) -> ClipFilter {
        let all = Self.allCases
        let index = all.firstIndex(of: self)!
        let count = all.count
        return all[((index + step) % count + count) % count]
    }
}

/// Fast, forgiving search over the history.
///
/// Every word of the query must appear in the item, either as a substring (strong match)
/// or as an in-order subsequence of characters (weak, "fuzzy" match). Matching ignores case
/// and diacritics. Results are ranked by match quality, then by recency.
public enum ClipSearch {
    public static func results(in items: [ClipItem], query: String, filter: ClipFilter) -> [ClipItem] {
        let filtered = items.filter(filter.accepts)
        let tokens = ClipFormatting.fold(query)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !tokens.isEmpty else { return filtered }

        var scored: [(item: ClipItem, score: Int, order: Int)] = []
        scored.reserveCapacity(filtered.count)
        for (order, item) in filtered.enumerated() {
            if let score = score(tokens: tokens, in: searchableText(for: item)) {
                scored.append((item, score, order))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        return scored.map(\.item)
    }

    /// Everything a user might remember about an item.
    public static func searchableText(for item: ClipItem) -> String {
        var parts: [String] = []
        if let text = item.text { parts.append(String(text.prefix(20_000))) }
        if let title = item.linkTitle { parts.append(title) }
        if let host = item.url?.host { parts.append(host) }
        if let ocr = item.recognizedText { parts.append(String(ocr.prefix(20_000))) }
        parts += item.fileURLs.map(\.lastPathComponent)
        if let app = item.sourceAppName { parts.append(app) }
        return ClipFormatting.fold(parts.joined(separator: "\n"))
    }

    /// Returns nil when any token fails to match.
    static func score(tokens: [String], in haystack: String) -> Int? {
        var total = 0
        for token in tokens {
            if let range = haystack.range(of: token) {
                var s = 100 + token.count * 4
                // Prefer matches at the start of a word.
                if range.lowerBound == haystack.startIndex || !haystack[haystack.index(before: range.lowerBound)].isLetter {
                    s += 40
                }
                total += s
            } else if token.count >= 3, isSubsequence(token, of: haystack) {
                total += 10
            } else {
                return nil
            }
        }
        return total
    }

    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = needle.makeIterator()
        guard var current = it.next() else { return true }
        for ch in haystack where ch == current {
            guard let next = it.next() else { return true }
            current = next
        }
        return false
    }
}
