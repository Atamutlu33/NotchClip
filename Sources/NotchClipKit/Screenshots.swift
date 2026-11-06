import AppKit
import UniformTypeIdentifiers

/// Read/write access to another app's preferences domain. Injectable so tests never touch the real system.
public protocol PreferencesDomain: AnyObject {
    func value(forKey key: String) -> Any?
    /// Setting nil removes the key.
    func set(_ value: Any?, forKey key: String)
}

/// The system screenshot tool's preferences (`defaults … com.apple.screencapture`).
public final class ScreencapturePreferences: PreferencesDomain {
    public static let domain = "com.apple.screencapture"
    public init() {}

    public func value(forKey key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, Self.domain as CFString)
    }

    public func set(_ value: Any?, forKey key: String) {
        let plist: CFPropertyList? = value.map { $0 as AnyObject }
        CFPreferencesSetAppValue(key as CFString, plist, Self.domain as CFString)
        CFPreferencesAppSynchronize(Self.domain as CFString)
    }
}

public final class InMemoryPreferences: PreferencesDomain {
    public private(set) var values: [String: Any]
    public init(_ values: [String: Any] = [:]) { self.values = values }
    public func value(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}

/// Points ⌘⇧3 / ⌘⇧4 / ⌘⇧5 at NotchClip's private inbox instead of the Desktop,
/// and puts the user's own settings back when turned off or when the app quits.
@MainActor
public final class ScreenshotRouter {
    static let managedKeys = ["location", "target", "show-thumbnail"]
    static let activeKey = "screenshotRouter.active"
    static let backupKey = "screenshotRouter.backup"

    private let system: PreferencesDomain
    private let defaults: UserDefaults
    public let inbox: URL

    public init(system: PreferencesDomain, defaults: UserDefaults, inbox: URL) {
        self.system = system
        self.defaults = defaults
        self.inbox = inbox
    }

    /// True while the system is pointed at the inbox (survives crashes, so settings can be restored next launch).
    public var isActive: Bool { defaults.bool(forKey: Self.activeKey) }

    public func activate() {
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        if !isActive {
            var backup: [String: Any] = [:]
            for key in Self.managedKeys {
                if let value = system.value(forKey: key) { backup[key] = value }
            }
            defaults.set(backup, forKey: Self.backupKey)
            defaults.set(true, forKey: Self.activeKey)
        }
        system.set(inbox.path, forKey: "location")
        system.set("file", forKey: "target")
        // The floating thumbnail delays saving by ~5 s; without it screenshots arrive instantly.
        system.set(false, forKey: "show-thumbnail")
    }

    public func deactivate() {
        guard isActive else { return }
        let backup = defaults.dictionary(forKey: Self.backupKey) ?? [:]
        for key in Self.managedKeys {
            system.set(backup[key], forKey: key)
        }
        defaults.removeObject(forKey: Self.backupKey)
        defaults.set(false, forKey: Self.activeKey)
    }
}

/// Watches the inbox folder and hands over each finished screenshot or recording exactly once.
@MainActor
public final class ScreenshotInbox {
    public enum Kind: Equatable { case image, movie, other }

    public let directory: URL
    public var onFile: (URL, Kind) -> Void = { _, _ in }

    private var source: DispatchSourceFileSystemObject?
    private var inFlight = Set<String>()
    static let settleInterval: TimeInterval = 0.2
    static let maxChecks = 150

    public init(directory: URL) {
        self.directory = directory
    }

    public var isRunning: Bool { source != nil }

    public func start() {
        guard source == nil else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .link], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scan() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        scan() // Leftovers from a previous run (e.g. the app was not running).
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    public static func kind(of url: URL) -> Kind {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) { return .movie }
        return .other
    }

    /// Looks for new files. Hidden files are the screenshot tool's work in progress.
    public func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where !name.hasPrefix(".") && !inFlight.contains(name) {
            inFlight.insert(name)
            waitUntilComplete(directory.appendingPathComponent(name), lastSize: -1, checks: 0)
        }
    }

    /// Delivers a file once its size has stopped changing.
    private func waitUntilComplete(_ url: URL, lastSize: Int, checks: Int) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        if size < 0 && !FileManager.default.fileExists(atPath: url.path) {
            inFlight.remove(url.lastPathComponent)
            return
        }
        if size > 0 && size == lastSize || checks >= Self.maxChecks {
            inFlight.remove(url.lastPathComponent)
            onFile(url, Self.kind(of: url))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleInterval) { [weak self] in
            MainActor.assumeIsolated { self?.waitUntilComplete(url, lastSize: size, checks: checks + 1) }
        }
    }
}

/// Picks a free file name such as "Screenshot 2026-11-06 at 12.57.03 2.png".
public enum FileNaming {
    public static func screenshotName(for date: Date, ext: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Screenshot \(formatter.string(from: date)).\(ext)"
    }

    public static func uniqueURL(in directory: URL, name: String) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
