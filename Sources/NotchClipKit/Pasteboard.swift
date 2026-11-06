import AppKit
import Carbon.HIToolbox
import NotchClipCore

/// Content read from the pasteboard.
public enum CapturedClip: Equatable {
    case text(String)
    case image(Data)
    case files([URL])
}

/// The app that owned the pasteboard change.
public struct AppSource: Equatable, Sendable {
    public var bundleID: String?
    public var name: String?

    public init(bundleID: String?, name: String?) {
        self.bundleID = bundleID
        self.name = name
    }

    @MainActor public static var frontmost: AppSource? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return AppSource(bundleID: app.bundleIdentifier, name: app.localizedName)
    }
}

public struct CaptureOptions: Equatable, Sendable {
    public var images = true
    public var files = true
    public init(images: Bool = true, files: Bool = true) {
        self.images = images
        self.files = files
    }
}

/// Watches the pasteboard's change count and reports new content.
///
/// Reading `changeCount` is a cheap integer read, so a short polling interval costs nothing.
@MainActor
public final class ClipboardMonitor {
    public static let maximumTextUTF16 = 2_000_000

    public let pasteboard: NSPasteboard
    public var isPaused: @MainActor () -> Bool = { false }
    public var privacy: @MainActor () -> PrivacyPolicy = { PrivacyPolicy() }
    public var options: @MainActor () -> CaptureOptions = { CaptureOptions() }
    public var source: @MainActor () -> AppSource? = { AppSource.frontmost }
    public var onCapture: @MainActor (CapturedClip, AppSource?) -> Void = { _, _ in }

    private var lastChangeCount: Int
    private var ignoredChangeCounts = Set<Int>()
    private var timer: Timer?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        // Never import what was on the pasteboard before the app started.
        self.lastChangeCount = pasteboard.changeCount
    }

    public var isRunning: Bool { timer != nil }

    public func start(interval: TimeInterval = 0.25) {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkNow() }
        }
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Marks a change made by this app so it is not captured again.
    public func ignore(changeCount: Int) {
        ignoredChangeCounts.insert(changeCount)
        if ignoredChangeCounts.count > 64 { ignoredChangeCounts.remove(ignoredChangeCounts.min()!) }
    }

    /// Checks the pasteboard once. Returns true when content was captured.
    @discardableResult
    public func checkNow() -> Bool {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return false }
        lastChangeCount = count
        if ignoredChangeCounts.remove(count) != nil { return false }
        if isPaused() { return false }

        let types = (pasteboard.types ?? []).map(\.rawValue)
        let owner = source()
        if privacy().shouldIgnore(typeIdentifiers: types, sourceBundleID: owner?.bundleID) { return false }
        guard let clip = Self.read(pasteboard, options: options()) else { return false }
        onCapture(clip, owner)
        return true
    }

    static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png, .tiff, NSPasteboard.PasteboardType("public.jpeg"), NSPasteboard.PasteboardType("public.heic")
    ]

    /// Picks the most useful representation of the current pasteboard content.
    public static func read(_ pasteboard: NSPasteboard, options: CaptureOptions) -> CapturedClip? {
        let types = pasteboard.types ?? []

        if options.files, types.contains(.fileURL),
           let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return .files(urls)
        }

        let string = pasteboard.string(forType: .string)
        let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if options.images, let type = imageTypes.first(where: types.contains),
           let data = pasteboard.data(forType: type), !data.isEmpty {
            // Office apps put a picture next to copied text; the text is what the user wants then.
            // Browsers put the image URL next to a copied image; the image wins there.
            if trimmed.isEmpty || ClipClassifier.kind(forText: trimmed) == .link {
                return .image(data)
            }
        }

        if let string, !trimmed.isEmpty, string.utf16.count <= maximumTextUTF16 {
            return .text(string)
        }
        return nil
    }
}

/// Writes history items back to a pasteboard.
@MainActor
public enum PasteboardWriter {
    /// Returns false when the content no longer exists (e.g. a deleted file).
    @discardableResult
    public static func write(_ item: ClipItem, images: ImageStore, to pasteboard: NSPasteboard, plainTextOnly: Bool = false) -> Bool {
        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            pasteboard.clearContents()
            return pasteboard.setString(text, forType: .string)

        case .link:
            guard let text = item.text else { return false }
            let entry = NSPasteboardItem()
            entry.setString(text, forType: .string)
            if !plainTextOnly, let url = item.url {
                entry.setString(url.absoluteString, forType: .URL)
            }
            pasteboard.clearContents()
            return pasteboard.writeObjects([entry])

        case .image:
            guard let name = item.imageFileName, let png = images.data(for: name) else { return false }
            let entry = NSPasteboardItem()
            entry.setData(png, forType: .png)
            if let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation {
                entry.setData(tiff, forType: .tiff)
            }
            pasteboard.clearContents()
            return pasteboard.writeObjects([entry])

        case .file:
            let urls = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !urls.isEmpty else { return false }
            pasteboard.clearContents()
            return pasteboard.writeObjects(urls as [NSURL])
        }
    }
}

/// Sends ⌘V to the frontmost app. Requires the Accessibility permission.
@MainActor
public enum Paster {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    public static func promptForTrust() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    public static func sendPasteShortcut() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }
}
