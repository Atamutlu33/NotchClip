import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import NotchClipCore

/// Wires storage, capture, the notch shelf, settings and the menu bar together.
@MainActor
public final class AppController: NSObject, ShelfActions {
    public let paths: AppPaths
    public let settings: AppSettings
    public let store: ClipStore
    public let imageStore: ImageStore
    public let model: ShelfModel
    public let monitor: ClipboardMonitor
    public let pasteboard: NSPasteboard
    public private(set) var windowController: NotchWindowController?

    /// Injectable for tests: sends ⌘V.
    public var pasteHandler: @MainActor () -> Void = { Paster.sendPasteShortcut() }
    /// Injectable for tests: whether ⌘V can be sent.
    public var isTrusted: @MainActor () -> Bool = { Paster.isTrusted }
    /// Injectable for tests: shows the Accessibility prompt.
    public var requestTrust: @MainActor () -> Void = { Paster.promptForTrust() }

    private let enableUI: Bool
    private var statusItem: NSStatusItem?
    private var menuTargets: [MenuTarget] = []
    private var screenshotWatcher: ScreenshotWatcher?
    private var settingsWindow: SettingsWindowController?
    private var cancellables = Set<AnyCancellable>()
    private var saveScheduled = false
    private var retentionTimer: Timer?
    private var registeredHotKey: HotKeyPreset?
    private var askedForTrust = false
    private var started = false

    static let dropSource = AppSource(bundleID: nil, name: "Dropped on notch")

    public init(paths: AppPaths = .standard(), defaults: UserDefaults = .standard,
                pasteboard: NSPasteboard = .general, enableUI: Bool = true) {
        try? paths.prepare()
        self.paths = paths
        self.pasteboard = pasteboard
        self.enableUI = enableUI
        settings = AppSettings(defaults: defaults)
        imageStore = ImageStore(directory: paths.images)
        store = ClipStore(backing: JSONFileBacking(url: paths.history), policy: settings.retentionPolicy)
        model = ShelfModel(imageStore: imageStore)
        monitor = ClipboardMonitor(pasteboard: pasteboard)
        super.init()

        model.actions = self
        model.isPaused = settings.isPaused
        model.setItems(store.items)
        store.onChange = { [weak self] in self?.storeChanged() }
        store.onRemove = { [weak self] removed in self?.itemsRemoved(removed) }
        imageStore.removeOrphans(keeping: Set(store.items.compactMap(\.imageFileName)))

        monitor.isPaused = { [weak self] in self?.settings.isPaused ?? true }
        monitor.privacy = { [weak self] in self?.settings.privacyPolicy ?? PrivacyPolicy() }
        monitor.options = { [weak self] in self?.settings.captureOptions ?? CaptureOptions() }
        monitor.onCapture = { [weak self] clip, source in self?.handle(clip, source: source) }
    }

    // MARK: Lifecycle

    public func start() {
        guard !started else { return }
        started = true
        monitor.start()
        if enableUI { buildUI() }
        applySettings()
        settings.objectWillChange
            .sink { [weak self] _ in
                // objectWillChange fires before the new value is stored.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.applySettings() } }
            }
            .store(in: &cancellables)

        let timer = Timer(timeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.applyRetention() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer
    }

    public func stop() {
        monitor.stop()
        screenshotWatcher?.stop()
        retentionTimer?.invalidate()
        HotKeyCenter.shared.unregister()
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        windowController?.panel.orderOut(nil)
        flush()
    }

    /// Writes pending changes to disk now.
    public func flush() {
        saveScheduled = false
        store.persist()
    }

    private func buildUI() {
        let controller = NotchWindowController(model: model)
        controller.hoverEnabled = { [weak self] in self?.settings.hoverToOpen ?? false }
        controller.show()
        windowController = controller
        HotKeyCenter.shared.action = { [weak self] in self?.windowController?.toggle() }
        settingsWindow = SettingsWindowController { [unowned self] in
            AnyView(SettingsView(settings: self.settings, commands: SettingsCommands(
                clearHistory: { [weak self] in self?.store.clearUnpinned() },
                openDataFolder: { [weak self] in
                    guard let self else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([self.paths.history])
                },
                historyCount: { [weak self] in self?.store.items.count ?? 0 })))
        }
    }

    private func applySettings() {
        store.policy = settings.retentionPolicy
        model.isPaused = settings.isPaused

        if settings.watchScreenshots {
            if screenshotWatcher == nil {
                screenshotWatcher = ScreenshotWatcher { [weak self] url in self?.ingestScreenshot(url) }
            }
            screenshotWatcher?.start()
        } else {
            screenshotWatcher?.stop()
        }

        guard enableUI else { return }
        if registeredHotKey != settings.hotKey {
            registeredHotKey = settings.hotKey
            if !HotKeyCenter.shared.register(settings.hotKey) {
                NSLog("NotchClip: shortcut \(settings.hotKey.title) is already used by another app")
            }
        }
        updateStatusItem()
    }

    /// First launch: show the shelf briefly so people discover where it lives.
    public func showWelcome() {
        guard let windowController else { return }
        windowController.expand(reason: .programmatic)
        model.showToast("Hi! Hover the notch or press \(settings.hotKey.title) any time", symbol: "hand.wave.fill", duration: 4)
    }

    // MARK: Capture

    /// Adds captured content. Returns a task for asynchronous work (image processing, OCR, titles) so tests can await it.
    @discardableResult
    public func handle(_ clip: CapturedClip, source: AppSource?) -> Task<Void, Never>? {
        let now = Date()
        switch clip {
        case .text(let string):
            guard let item = ClipItem.fromText(string, at: now, sourceBundleID: source?.bundleID, sourceAppName: source?.name) else { return nil }
            if case .inserted(let added) = store.add(item), added.kind == .link {
                return fetchTitle(for: added)
            }
            return nil
        case .files(let urls):
            guard let item = ClipItem.fromFiles(urls.map(\.path), at: now, sourceBundleID: source?.bundleID, sourceAppName: source?.name) else { return nil }
            store.add(item)
            return nil
        case .image(let data):
            return ingestImage(data, source: source)
        }
    }

    @discardableResult
    func ingestImage(_ data: Data, source: AppSource?) -> Task<Void, Never> {
        Task { [weak self] in
            let normalized = await Task.detached(priority: .userInitiated) { ImageCodec.normalize(data) }.value
            guard let self, let normalized else { return }
            let hash = ContentHash.forImage(normalized.png)
            let now = Date()
            if let existing = self.store.item(hash: hash), let name = existing.imageFileName, self.imageStore.exists(name) {
                var refreshed = existing
                refreshed.sourceBundleID = source?.bundleID
                refreshed.sourceAppName = source?.name
                self.store.add(refreshed)
                return
            }
            let fileName: String
            do {
                fileName = try self.imageStore.save(pngData: normalized.png, hash: hash)
            } catch {
                NSLog("NotchClip: could not save image: \(error.localizedDescription)")
                return
            }
            let item = ClipItem.fromImage(fileName: fileName, hash: hash, width: normalized.width, height: normalized.height,
                                          at: now, sourceBundleID: source?.bundleID, sourceAppName: source?.name)
            self.store.add(item)
            if self.settings.recognizeText {
                let text = await OCRService.recognizeText(at: self.imageStore.url(for: fileName))
                if let text { self.store.update(id: item.id) { $0.recognizedText = text } }
            }
        }
    }

    private func ingestScreenshot(_ url: URL) {
        guard !settings.isPaused, let data = try? Data(contentsOf: url) else { return }
        ingestImage(data, source: AppSource(bundleID: "com.apple.screencaptureui", name: "Screenshot"))
    }

    private func fetchTitle(for item: ClipItem) -> Task<Void, Never>? {
        guard settings.fetchLinkTitles, let url = item.url, LinkPrivacy.isSafeToFetch(url) else { return nil }
        return Task { [weak self] in
            guard let title = await LinkTitleService.fetchTitle(for: url) else { return }
            self?.store.update(id: item.id) { $0.linkTitle = title }
        }
    }

    // MARK: Store events

    private func storeChanged() {
        model.setItems(store.items)
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.saveScheduled else { return }
                self.flush()
            }
        }
    }

    private func itemsRemoved(_ removed: [ClipItem]) {
        let stillUsed = Set(store.items.compactMap(\.imageFileName))
        for name in removed.compactMap(\.imageFileName) where !stillUsed.contains(name) {
            imageStore.delete(name)
        }
    }

    // MARK: ShelfActions

    public func performPrimary(_ item: ClipItem) {
        guard writeToPasteboard(item) else { return }
        guard settings.pasteOnSelect else {
            model.showToast("Copied")
            collapse(after: 0.5)
            return
        }
        if isTrusted() {
            windowController?.collapse(immediately: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
                MainActor.assumeIsolated { self?.pasteHandler() }
            }
        } else {
            if !askedForTrust {
                askedForTrust = true
                requestTrust()
            }
            model.showToast("Copied · press ⌘V (allow Accessibility to paste automatically)", symbol: "doc.on.doc.fill", duration: 2.4)
            collapse(after: 1.8)
        }
    }

    public func copy(_ item: ClipItem) {
        guard writeToPasteboard(item) else { return }
        model.showToast("Copied")
    }

    public func togglePin(_ item: ClipItem) {
        store.togglePin(id: item.id)
        let pinned = store.item(id: item.id)?.isPinned ?? false
        model.showToast(pinned ? "Pinned · kept forever" : "Unpinned", symbol: pinned ? "pin.fill" : "pin.slash")
    }

    public func delete(_ item: ClipItem) {
        store.delete(ids: [item.id])
    }

    public func open(_ item: ClipItem) {
        switch item.kind {
        case .link:
            if let url = item.url { NSWorkspace.shared.open(url) }
        case .file:
            let existing = item.fileURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { model.showToast("File no longer exists", symbol: "exclamationmark.triangle.fill"); return }
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        case .image:
            if let name = item.imageFileName { NSWorkspace.shared.activateFileViewerSelecting([imageStore.url(for: name)]) }
        case .text:
            return
        }
        windowController?.collapse()
    }

    public func dragProvider(for item: ClipItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .link:
            if let url = item.url { return NSItemProvider(object: url as NSURL) }
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .image:
            if let name = item.imageFileName, let provider = NSItemProvider(contentsOf: imageStore.url(for: name)) {
                provider.suggestedName = "NotchClip \(item.createdAt.formatted(.iso8601.year().month().day()))"
                return provider
            }
        case .file:
            if let url = item.fileURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
               let provider = NSItemProvider(contentsOf: url) {
                return provider
            }
        }
        return NSItemProvider()
    }

    public func ingestDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task { [weak self] in await self?.collectDrop(providers) }
        return true
    }

    /// Loads dropped items: files become one file clip, images and text become their own clips.
    func collectDrop(_ providers: [NSItemProvider]) async {
        var files: [URL] = []
        var added = 0
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let url = await Self.loadURL(provider), url.isFileURL {
                files.append(url)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
                      let data = await Self.loadData(provider, type: UTType.image.identifier) {
                await ingestImage(data, source: Self.dropSource).value
                added += 1
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                      let url = await Self.loadURL(provider) {
                await handle(.text(url.absoluteString), source: Self.dropSource)?.value
                added += 1
            } else if provider.canLoadObject(ofClass: NSString.self), let text = await Self.loadString(provider) {
                await handle(.text(text), source: Self.dropSource)?.value
                added += 1
            }
        }
        if !files.isEmpty {
            handle(.files(files), source: Self.dropSource)
            added += 1
        }
        if added > 0 { model.showToast("Kept on the shelf", symbol: "tray.and.arrow.down.fill") }
    }

    nonisolated static func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    nonisolated static func loadString(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { string, _ in continuation.resume(returning: string) }
        }
    }

    nonisolated static func loadData(_ provider: NSItemProvider, type: String) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in continuation.resume(returning: data) }
        }
    }

    public func collapseShelf() { windowController?.collapse() }

    public func openSettings() {
        windowController?.collapse()
        settingsWindow?.show()
    }

    public func togglePause() {
        settings.isPaused.toggle()
        model.isPaused = settings.isPaused
        model.showToast(settings.isPaused ? "Capture paused" : "Capture resumed",
                        symbol: settings.isPaused ? "pause.circle.fill" : "play.circle.fill")
        updateStatusItem()
    }

    // MARK: Helpers

    private func writeToPasteboard(_ item: ClipItem) -> Bool {
        guard PasteboardWriter.write(item, images: imageStore, to: pasteboard) else {
            model.showToast(item.kind == .file ? "File no longer exists" : "This clip is no longer available",
                            symbol: "exclamationmark.triangle.fill")
            return false
        }
        monitor.ignore(changeCount: pasteboard.changeCount)
        store.markUsed(id: item.id)
        return true
    }

    private func collapse(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated { self?.windowController?.collapse() }
        }
    }

    // MARK: Menu bar

    private func updateStatusItem() {
        guard enableUI else { return }
        guard settings.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let symbol = settings.isPaused ? "pause.rectangle" : "rectangle.topthird.inset.filled"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NotchClip")
        item.button?.toolTip = "NotchClip"

        menuTargets.removeAll()
        let menu = NSMenu()
        let hotKey = settings.hotKey == .off ? "" : "  \(settings.hotKey.title)"
        menu.addItem(menuItem("Open Shelf\(hotKey)") { [weak self] in self?.windowController?.expand(reason: .keyboard) })
        menu.addItem(menuItem(settings.isPaused ? "Resume Capture" : "Pause Capture") { [weak self] in self?.togglePause() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Clear Unpinned History…") { [weak self] in self?.confirmClear() })
        menu.addItem(menuItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit NotchClip", key: "q") { NSApp.terminate(nil) })
        item.menu = menu
    }

    private func menuItem(_ title: String, key: String = "", action: @escaping () -> Void) -> NSMenuItem {
        let target = MenuTarget(action)
        menuTargets.append(target)
        let item = NSMenuItem(title: title, action: #selector(MenuTarget.run), keyEquivalent: key)
        item.target = target
        return item
    }

    private func confirmClear() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Clear all unpinned clips?"
        alert.informativeText = "Pinned clips stay. This cannot be undone."
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        if alert.runModal() == .alertFirstButtonReturn { store.clearUnpinned() }
    }
}

private final class MenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
