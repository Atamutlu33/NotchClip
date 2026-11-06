import AppKit
import ImageIO
import NotchClipCore

/// On-disk locations. `NOTCHCLIP_HOME` overrides the root (used by tests and the self-test).
public struct AppPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var images: URL { root.appendingPathComponent("Images", isDirectory: true) }
    public var history: URL { root.appendingPathComponent("history.json") }
    /// Where the system screenshot tool writes while NotchClip handles screenshots.
    public var screenshotInbox: URL { root.appendingPathComponent("ScreenshotInbox", isDirectory: true) }
    /// Screen recordings kept on the shelf (owned by NotchClip, deleted with their clip).
    public var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }

    public static func standard() -> AppPaths {
        if let override = ProcessInfo.processInfo.environment["NOTCHCLIP_HOME"], !override.isEmpty {
            return AppPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return AppPaths(root: support.appendingPathComponent("NotchClip", isDirectory: true))
    }

    public static func temporary() -> AppPaths {
        AppPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent("NotchClip-\(UUID().uuidString)", isDirectory: true))
    }

    public func prepare() throws {
        for dir in [images, screenshotInbox, recordings] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}

/// Converts any pasteboard image into PNG data with its pixel size.
public enum ImageCodec {
    public static let maximumInputBytes = 64 * 1024 * 1024
    public static let maximumPixels = 60_000_000

    public struct Normalized: Sendable {
        public let png: Data
        public let width: Int
        public let height: Int
    }

    public static func normalize(_ data: Data) -> Normalized? {
        guard !data.isEmpty, data.count <= maximumInputBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        guard width > 0, height > 0, width * height <= maximumPixels else { return nil }
        // PNG input is kept byte for byte: no re-encoding cost and a stable identity.
        if isPNG(data) { return Normalized(png: data, width: width, height: height) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return Normalized(png: png, width: width, height: height)
    }

    static func isPNG(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }
}

/// Stores captured images as PNG files named after their content hash, with a thumbnail cache.
public final class ImageStore {
    public let directory: URL
    private let thumbnails = NSCache<NSString, NSImage>()

    public init(directory: URL) {
        self.directory = directory
        thumbnails.countLimit = 400
    }

    public static func fileName(forHash hash: String) -> String {
        let hex = hash.hasPrefix("i:") ? String(hash.dropFirst(2)) : hash
        return hex + ".png"
    }

    /// Saves PNG data and returns the file name. Saving identical content again is a no-op.
    @discardableResult
    public func save(pngData: Data, hash: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = Self.fileName(forHash: hash)
        let url = self.url(for: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try pngData.write(to: url, options: [.atomic])
        }
        return name
    }

    public func url(for fileName: String) -> URL { directory.appendingPathComponent(fileName) }

    public func exists(_ fileName: String) -> Bool { FileManager.default.fileExists(atPath: url(for: fileName).path) }

    public func data(for fileName: String) -> Data? { try? Data(contentsOf: url(for: fileName)) }

    public func fullImage(_ fileName: String) -> NSImage? { NSImage(contentsOf: url(for: fileName)) }

    /// A downscaled image for cards; decoded once and cached.
    public func thumbnail(_ fileName: String, maxPixel: Int = 360) -> NSImage? {
        let key = "\(fileName)@\(maxPixel)" as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        guard let source = CGImageSourceCreateWithURL(url(for: fileName) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbnails.setObject(image, forKey: key)
        return image
    }

    public func delete(_ fileName: String) {
        try? FileManager.default.removeItem(at: url(for: fileName))
        thumbnails.removeAllObjects()
    }

    /// Deletes image files that no history item refers to (e.g. after a crash).
    public func removeOrphans(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for file in files where file.hasSuffix(".png") && !names.contains(file) {
            try? FileManager.default.removeItem(at: url(for: file))
        }
    }
}
