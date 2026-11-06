import AppKit
import Carbon.HIToolbox
import LinkPresentation
import UniformTypeIdentifiers
import Vision

/// On-device text recognition for images (Apple Vision). Nothing leaves the Mac.
public enum OCRService {
    public static func recognizeText(at url: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            let handler = VNImageRequestHandler(url: url, options: [:])
            do {
                try handler.perform([request])
            } catch {
                return nil
            }
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }.value
    }
}

/// Fetches a web page title for link cards.
@MainActor
public enum LinkTitleService {
    public static func fetchTitle(for url: URL) async -> String? {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        provider.shouldFetchSubresources = false
        do {
            let metadata = try await provider.startFetchingMetadata(for: url)
            let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (title?.isEmpty ?? true) ? nil : title
        } catch {
            return nil
        }
    }
}

/// Reports new screenshots (any language, any save location) using Spotlight's screen-capture flag.
@MainActor
public final class ScreenshotWatcher: NSObject {
    private var query: NSMetadataQuery?
    private var startedAt = Date()
    private var seen = Set<String>()
    private let onScreenshot: @MainActor (URL) -> Void

    public init(onScreenshot: @escaping @MainActor (URL) -> Void) {
        self.onScreenshot = onScreenshot
    }

    public var isRunning: Bool { query != nil }

    public func start() {
        guard query == nil else { return }
        startedAt = Date()
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1")
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        NotificationCenter.default.addObserver(self, selector: #selector(queryUpdated(_:)),
                                               name: .NSMetadataQueryDidUpdate, object: query)
        self.query = query
        query.start()
    }

    public func stop() {
        guard let query else { return }
        query.stop()
        NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidUpdate, object: query)
        self.query = nil
    }

    @objc private func queryUpdated(_ note: Notification) {
        let keys = [NSMetadataQueryUpdateAddedItemsKey, NSMetadataQueryUpdateChangedItemsKey]
        let items = keys.flatMap { (note.userInfo?[$0] as? [NSMetadataItem]) ?? [] }
        for item in items {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  !seen.contains(path) else { continue }
            let created = item.value(forAttribute: NSMetadataItemFSCreationDateKey) as? Date ?? .distantPast
            guard created >= startedAt.addingTimeInterval(-2) else { continue }
            let url = URL(fileURLWithPath: path)
            guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { continue }
            seen.insert(path)
            // Give the screenshot tool a moment to finish writing the file.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { self?.onScreenshot(url) }
            }
        }
    }
}

/// Keyboard shortcut choices for opening the shelf.
public enum HotKeyPreset: String, CaseIterable, Identifiable, Sendable {
    case optionCommandV
    case controlOptionV
    case shiftCommandV
    case controlCommandV
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .optionCommandV: return "⌥⌘V"
        case .controlOptionV: return "⌃⌥V"
        case .shiftCommandV: return "⇧⌘V"
        case .controlCommandV: return "⌃⌘V"
        case .off: return "Off"
        }
    }

    var keyCode: UInt32 { UInt32(kVK_ANSI_V) }

    var carbonModifiers: UInt32? {
        switch self {
        case .optionCommandV: return UInt32(optionKey | cmdKey)
        case .controlOptionV: return UInt32(controlKey | optionKey)
        case .shiftCommandV: return UInt32(shiftKey | cmdKey)
        case .controlCommandV: return UInt32(controlKey | cmdKey)
        case .off: return nil
        }
    }
}

/// A single global shortcut registered through Carbon (no Accessibility permission needed).
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    public var action: (@MainActor () -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() {}

    /// Returns false if another app already owns the combination.
    @discardableResult
    public func register(_ preset: HotKeyPreset) -> Bool {
        unregister()
        guard let modifiers = preset.carbonModifiers else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4E43_4C50), id: 1) // "NCLP"
        let status = RegisterEventHotKey(preset.keyCode, modifiers, id, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        return true
    }

    public func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { HotKeyCenter.shared.action?() }
            }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
