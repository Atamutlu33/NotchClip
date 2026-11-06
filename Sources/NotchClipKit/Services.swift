import AppKit
import Carbon.HIToolbox
import LinkPresentation
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
