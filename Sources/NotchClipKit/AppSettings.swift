import Foundation
import NotchClipCore

/// User preferences, persisted in UserDefaults.
@MainActor
public final class AppSettings: ObservableObject {
    enum Key {
        static let captureImages = "captureImages"
        static let captureFiles = "captureFiles"
        static let watchScreenshots = "watchScreenshots"
        static let fetchLinkTitles = "fetchLinkTitles"
        static let recognizeText = "recognizeText"
        static let historyDays = "historyDays"
        static let maxItems = "maxItems"
        static let hoverToOpen = "hoverToOpen"
        static let hotKey = "hotKey"
        static let pasteOnSelect = "pasteOnSelect"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let ignoredApps = "ignoredApps"
        static let isPaused = "isPaused"
        static let hasLaunchedBefore = "hasLaunchedBefore"
    }

    /// Choices offered for how long unpinned history is kept. 0 means forever.
    public static let historyDayOptions = [1, 7, 30, 90, 365, 0]
    public static let maxItemOptions = [100, 300, 1000, 3000]

    private let defaults: UserDefaults

    @Published public var captureImages: Bool { didSet { defaults.set(captureImages, forKey: Key.captureImages) } }
    @Published public var captureFiles: Bool { didSet { defaults.set(captureFiles, forKey: Key.captureFiles) } }
    @Published public var watchScreenshots: Bool { didSet { defaults.set(watchScreenshots, forKey: Key.watchScreenshots) } }
    @Published public var fetchLinkTitles: Bool { didSet { defaults.set(fetchLinkTitles, forKey: Key.fetchLinkTitles) } }
    @Published public var recognizeText: Bool { didSet { defaults.set(recognizeText, forKey: Key.recognizeText) } }
    @Published public var historyDays: Int { didSet { defaults.set(historyDays, forKey: Key.historyDays) } }
    @Published public var maxItems: Int { didSet { defaults.set(maxItems, forKey: Key.maxItems) } }
    @Published public var hoverToOpen: Bool { didSet { defaults.set(hoverToOpen, forKey: Key.hoverToOpen) } }
    @Published public var hotKey: HotKeyPreset { didSet { defaults.set(hotKey.rawValue, forKey: Key.hotKey) } }
    @Published public var pasteOnSelect: Bool { didSet { defaults.set(pasteOnSelect, forKey: Key.pasteOnSelect) } }
    @Published public var showMenuBarIcon: Bool { didSet { defaults.set(showMenuBarIcon, forKey: Key.showMenuBarIcon) } }
    @Published public var ignoredApps: [String] { didSet { defaults.set(ignoredApps, forKey: Key.ignoredApps) } }
    @Published public var isPaused: Bool { didSet { defaults.set(isPaused, forKey: Key.isPaused) } }

    /// True only on the very first launch.
    public let isFirstLaunch: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.captureImages: true,
            Key.captureFiles: true,
            Key.watchScreenshots: false,
            Key.fetchLinkTitles: true,
            Key.recognizeText: true,
            Key.historyDays: 30,
            Key.maxItems: 300,
            Key.hoverToOpen: true,
            Key.hotKey: HotKeyPreset.optionCommandV.rawValue,
            Key.pasteOnSelect: true,
            Key.showMenuBarIcon: true,
            Key.ignoredApps: [String](),
            Key.isPaused: false
        ])
        captureImages = defaults.bool(forKey: Key.captureImages)
        captureFiles = defaults.bool(forKey: Key.captureFiles)
        watchScreenshots = defaults.bool(forKey: Key.watchScreenshots)
        fetchLinkTitles = defaults.bool(forKey: Key.fetchLinkTitles)
        recognizeText = defaults.bool(forKey: Key.recognizeText)
        historyDays = defaults.integer(forKey: Key.historyDays)
        maxItems = max(10, defaults.integer(forKey: Key.maxItems))
        hoverToOpen = defaults.bool(forKey: Key.hoverToOpen)
        hotKey = HotKeyPreset(rawValue: defaults.string(forKey: Key.hotKey) ?? "") ?? .optionCommandV
        pasteOnSelect = defaults.bool(forKey: Key.pasteOnSelect)
        showMenuBarIcon = defaults.bool(forKey: Key.showMenuBarIcon)
        ignoredApps = defaults.stringArray(forKey: Key.ignoredApps) ?? []
        isPaused = defaults.bool(forKey: Key.isPaused)
        isFirstLaunch = !defaults.bool(forKey: Key.hasLaunchedBefore)
        defaults.set(true, forKey: Key.hasLaunchedBefore)
    }

    public var retentionPolicy: RetentionPolicy {
        RetentionPolicy(maxAgeDays: historyDays > 0 ? historyDays : nil, maxItems: maxItems)
    }

    public var privacyPolicy: PrivacyPolicy {
        PrivacyPolicy(extraIgnoredApps: Set(ignoredApps))
    }

    public var captureOptions: CaptureOptions {
        CaptureOptions(images: captureImages, files: captureFiles)
    }

    public static func historyTitle(days: Int) -> String {
        switch days {
        case 0: return "Forever"
        case 1: return "1 day"
        case 365: return "1 year"
        default: return "\(days) days"
        }
    }
}
