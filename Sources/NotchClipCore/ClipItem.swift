import Foundation

/// What kind of content a clip holds.
public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case link
    case image
    case file
}

/// One entry in the clipboard history.
public struct ClipItem: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: ClipKind
    /// When the content was first captured.
    public var createdAt: Date
    /// When the content was last copied, captured again or pasted. History is ordered by this.
    public var lastUsedAt: Date
    /// Text for `.text` and the URL string for `.link`.
    public var text: String?
    /// File name inside the image store for `.image`.
    public var imageFileName: String?
    public var imagePixelWidth: Int?
    public var imagePixelHeight: Int?
    /// Absolute paths for `.file`.
    public var filePaths: [String]?
    public var sourceBundleID: String?
    public var sourceAppName: String?
    public var isPinned: Bool
    /// Identity used for de-duplication.
    public var contentHash: String
    /// Text recognised in an image (on-device OCR).
    public var recognizedText: String?
    /// Page title fetched for a link.
    public var linkTitle: String?
    public var useCount: Int

    public init(
        id: UUID = UUID(),
        kind: ClipKind,
        createdAt: Date,
        lastUsedAt: Date? = nil,
        text: String? = nil,
        imageFileName: String? = nil,
        imagePixelWidth: Int? = nil,
        imagePixelHeight: Int? = nil,
        filePaths: [String]? = nil,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil,
        isPinned: Bool = false,
        contentHash: String,
        recognizedText: String? = nil,
        linkTitle: String? = nil,
        useCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt ?? createdAt
        self.text = text
        self.imageFileName = imageFileName
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.filePaths = filePaths
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
        self.isPinned = isPinned
        self.contentHash = contentHash
        self.recognizedText = recognizedText
        self.linkTitle = linkTitle
        self.useCount = useCount
    }
}

public extension ClipItem {
    /// Builds a text or link item from captured text. Returns nil for empty or whitespace-only text.
    static func fromText(_ raw: String, at date: Date, sourceBundleID: String? = nil, sourceAppName: String? = nil) -> ClipItem? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let kind = ClipClassifier.kind(forText: raw)
        let stored = kind == .link ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        return ClipItem(kind: kind, createdAt: date, text: stored,
                        sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
                        contentHash: ContentHash.forText(stored))
    }

    /// Builds a file item from file paths. Returns nil when there are no paths.
    static func fromFiles(_ paths: [String], at date: Date, sourceBundleID: String? = nil, sourceAppName: String? = nil) -> ClipItem? {
        guard !paths.isEmpty else { return nil }
        return ClipItem(kind: .file, createdAt: date, filePaths: paths,
                        sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
                        contentHash: ContentHash.forFiles(paths))
    }

    /// Builds an image item whose PNG is stored under `fileName`.
    static func fromImage(fileName: String, hash: String, width: Int, height: Int, at date: Date,
                          sourceBundleID: String? = nil, sourceAppName: String? = nil) -> ClipItem {
        ClipItem(kind: .image, createdAt: date, imageFileName: fileName,
                 imagePixelWidth: width, imagePixelHeight: height,
                 sourceBundleID: sourceBundleID, sourceAppName: sourceAppName,
                 contentHash: hash)
    }

    /// The URL of a link item.
    var url: URL? {
        guard kind == .link, let text else { return nil }
        return ClipClassifier.linkURL(from: text)
    }

    /// File URLs of a file item.
    var fileURLs: [URL] {
        (filePaths ?? []).map { URL(fileURLWithPath: $0) }
    }

    /// A short, single-line title for cards and menus.
    var displayTitle: String {
        switch kind {
        case .text:
            return ClipFormatting.singleLine(text ?? "", limit: 120)
        case .link:
            if let title = linkTitle, !title.isEmpty { return ClipFormatting.singleLine(title, limit: 120) }
            return url?.host ?? ClipFormatting.singleLine(text ?? "", limit: 120)
        case .image:
            if let w = imagePixelWidth, let h = imagePixelHeight { return "Image \(w)×\(h)" }
            return "Image"
        case .file:
            let names = fileURLs.map(\.lastPathComponent)
            guard let first = names.first else { return "Files" }
            return names.count == 1 ? first : "\(first) +\(names.count - 1)"
        }
    }
}
