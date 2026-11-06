import AppKit
import XCTest
@testable import NotchClipCore
@testable import NotchClipKit

@MainActor
final class LayoutTests: XCTestCase {
    func testNotchedScreen() {
        // 14" MacBook Pro: 1512 wide, notch about 185 pt, safe area 32 pt.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = ShelfLayout.make(screenFrame: screen, safeAreaTop: 32, leftAuxWidth: 663, rightAuxWidth: 664)
        XCTAssertTrue(layout.hasNotch)
        XCTAssertEqual(layout.notchSize, CGSize(width: 185, height: 32))
        let collapsed = layout.collapsedFrame(in: screen)
        XCTAssertEqual(collapsed.maxY, screen.maxY)
        XCTAssertEqual(collapsed.midX, screen.midX, accuracy: 1)
        let expanded = layout.expandedFrame(in: screen, previewing: false)
        XCTAssertEqual(expanded.maxY, screen.maxY)
        XCTAssertEqual(expanded.midX, screen.midX, accuracy: 1)
        XCTAssertGreaterThan(layout.expandedFrame(in: screen, previewing: true).height, expanded.height)
        XCTAssertLessThanOrEqual(expanded.width, screen.width)
    }

    func testScreenWithoutNotchUsesTopEdgeHotZone() {
        let screen = CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        let layout = ShelfLayout.make(screenFrame: screen, safeAreaTop: 0, leftAuxWidth: nil, rightAuxWidth: nil)
        XCTAssertFalse(layout.hasNotch)
        let collapsed = layout.collapsedFrame(in: screen)
        XCTAssertEqual(collapsed.maxY, screen.maxY)
        XCTAssertEqual(collapsed.midX, screen.midX, accuracy: 1)
        XCTAssertLessThan(collapsed.height, 10)
        XCTAssertEqual(layout.shelfWidth, 760)
    }

    func testNarrowScreenShelfFits() {
        let screen = CGRect(x: 0, y: 0, width: 600, height: 400)
        let layout = ShelfLayout.make(screenFrame: screen, safeAreaTop: 0, leftAuxWidth: nil, rightAuxWidth: nil)
        XCTAssertEqual(layout.shelfWidth, 552)
    }
}

@MainActor
final class MockActions: ShelfActions {
    var log: [String] = []
    func performPrimary(_ item: ClipItem) { log.append("primary:\(item.text ?? "")") }
    func copy(_ item: ClipItem) { log.append("copy:\(item.text ?? "")") }
    func togglePin(_ item: ClipItem) { log.append("pin:\(item.text ?? "")") }
    func delete(_ item: ClipItem) { log.append("delete:\(item.text ?? "")") }
    func open(_ item: ClipItem) { log.append("open:\(item.text ?? "")") }
    func dragProvider(for item: ClipItem) -> NSItemProvider { NSItemProvider() }
    func ingestDrop(_ providers: [NSItemProvider]) -> Bool { true }
    func collapseShelf() { log.append("collapse") }
    func openSettings() { log.append("settings") }
    func togglePause() { log.append("pause") }
}

@MainActor
final class ShelfModelTests: XCTestCase {
    func makeModel(_ texts: [String]) -> (ShelfModel, MockActions) {
        let model = ShelfModel(imageStore: ImageStore(directory: FileManager.default.temporaryDirectory))
        let actions = MockActions()
        model.actions = actions
        let now = Date()
        model.setItems(texts.enumerated().map { i, t in ClipItem.fromText(t, at: now.addingTimeInterval(-Double(i)))! })
        model.prepareForOpening()
        return (model, actions)
    }

    func testSelectionMovesAndClamps() {
        let (model, _) = makeModel(["a", "b", "c"])
        XCTAssertEqual(model.selectedIndex, 0)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedIndex, 0)
        model.moveSelection(by: 1); model.moveSelection(by: 1); model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedIndex, 2)
        model.selectFirst()
        XCTAssertEqual(model.selectedIndex, 0)
        model.selectLast()
        XCTAssertEqual(model.selectedIndex, 2)
    }

    func testDeletingSelectedSelectsNeighbour() {
        let (model, _) = makeModel(["a", "b", "c"])
        model.moveSelection(by: 1)
        let remaining = model.allItems.filter { $0.text != "b" }
        model.setItems(remaining)
        XCTAssertEqual(model.selectedItem?.text, "c")
        model.setItems(remaining.filter { $0.text != "c" })
        XCTAssertEqual(model.selectedItem?.text, "a")
        model.setItems([])
        XCTAssertNil(model.selectedID)
    }

    func testQueryAndFilterResetSelection() {
        let (model, _) = makeModel(["apple pie", "banana", "apple juice"])
        model.moveSelection(by: 2)
        model.query = "banana"
        XCTAssertEqual(model.results.map(\.text), ["banana"])
        XCTAssertEqual(model.selectedItem?.text, "banana")
        model.query = ""
        model.filter = .pinned
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.selectedID)
    }

    func testNewItemsKeepSelection() {
        let (model, _) = makeModel(["a", "b"])
        model.moveSelection(by: 1)
        let selected = model.selectedID
        model.setItems([ClipItem.fromText("new", at: Date())!] + model.allItems)
        XCTAssertEqual(model.selectedID, selected)
    }

    func testPrepareForOpeningResetsState() {
        let (model, _) = makeModel(["a", "b"])
        model.query = "b"; model.filter = .text; model.isPreviewing = true
        model.prepareForOpening()
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.filter, .all)
        XCTAssertFalse(model.isPreviewing)
        XCTAssertEqual(model.selectedIndex, 0)
    }

    func testToast() async throws {
        let (model, _) = makeModel([])
        model.showToast("Hi", duration: 0.05)
        XCTAssertEqual(model.toast?.text, "Hi")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(model.toast)
    }
}

@MainActor
final class KeyHandlerTests: XCTestCase {
    typealias K = ShelfKeyHandler.Key

    func press(_ code: UInt16, _ model: ShelfModel, command: Bool = false, shift: Bool = false, chars: String = "") -> (handled: Bool, collapsed: Bool) {
        var collapsed = false
        let handled = ShelfKeyHandler.handle(keyCode: code, command: command, shift: shift, characters: chars,
                                             model: model, collapse: { collapsed = true })
        return (handled, collapsed)
    }

    func setUpModel() -> (ShelfModel, MockActions) {
        let model = ShelfModel(imageStore: ImageStore(directory: FileManager.default.temporaryDirectory))
        let actions = MockActions()
        model.actions = actions
        let now = Date()
        model.setItems(["one", "two", "three"].enumerated().map { ClipItem.fromText($1, at: now.addingTimeInterval(-Double($0)))! })
        model.prepareForOpening()
        return (model, actions)
    }

    func testArrowsReturnAndShortcuts() {
        let (model, actions) = setUpModel()
        XCTAssertTrue(press(K.right, model).handled)
        XCTAssertEqual(model.selectedItem?.text, "two")
        _ = press(K.returnKey, model)
        _ = press(K.returnKey, model, shift: true)
        _ = press(0, model, command: true, chars: "c")
        _ = press(0, model, command: true, chars: "p")
        _ = press(K.delete, model, command: true)
        _ = press(0, model, command: true, chars: "3")
        _ = press(0, model, command: true, chars: ",")
        XCTAssertEqual(actions.log, ["primary:two", "copy:two", "copy:two", "pin:two", "delete:two", "primary:three", "settings"])
    }

    func testEscapeLayers() {
        let (model, _) = setUpModel()
        model.isPreviewing = true
        model.query = "t"
        var r = press(K.escape, model)
        XCTAssertFalse(model.isPreviewing); XCTAssertEqual(model.query, "t"); XCTAssertFalse(r.collapsed)
        r = press(K.escape, model)
        XCTAssertEqual(model.query, ""); XCTAssertFalse(r.collapsed)
        r = press(K.escape, model)
        XCTAssertTrue(r.collapsed)
    }

    func testSpaceTogglesPreviewOnlyWithEmptyQuery() {
        let (model, _) = setUpModel()
        XCTAssertTrue(press(K.space, model).handled)
        XCTAssertTrue(model.isPreviewing)
        XCTAssertTrue(press(K.space, model).handled)
        XCTAssertFalse(model.isPreviewing)
        model.query = "o"
        XCTAssertFalse(press(K.space, model).handled, "Space types into a non-empty search")
    }

    func testTypingIsLeftToSearchField() {
        let (model, _) = setUpModel()
        XCTAssertFalse(press(0, model, chars: "a").handled)
        XCTAssertFalse(press(0, model, command: true, chars: "a").handled)
        XCTAssertFalse(press(0, model, command: true, chars: "v").handled)
        XCTAssertFalse(press(K.delete, model).handled)
    }

    func testTabCyclesFilters() {
        let (model, _) = setUpModel()
        _ = press(K.tab, model)
        XCTAssertEqual(model.filter, .text)
        _ = press(K.tab, model, shift: true)
        _ = press(K.tab, model, shift: true)
        XCTAssertEqual(model.filter, .pinned)
    }

    func testUpDownPreview() {
        let (model, _) = setUpModel()
        _ = press(K.down, model)
        XCTAssertTrue(model.isPreviewing)
        _ = press(K.up, model)
        XCTAssertFalse(model.isPreviewing)
    }
}

@MainActor
final class PasteboardTests: XCTestCase {
    var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchClipTests.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
    }

    func png(width: Int = 8, height: Int = 6) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testMonitorCapturesTextAndIgnoresOwnChanges() {
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        monitor.source = { AppSource(bundleID: "com.apple.Notes", name: "Notes") }
        var captured: [(CapturedClip, AppSource?)] = []
        monitor.onCapture = { captured.append(($0, $1)) }

        XCTAssertFalse(monitor.checkNow(), "nothing changed yet")
        pasteboard.clearContents(); pasteboard.setString("hi", forType: .string)
        XCTAssertTrue(monitor.checkNow())
        XCTAssertFalse(monitor.checkNow(), "same change count is read once")
        XCTAssertEqual(captured.first?.0, .text("hi"))
        XCTAssertEqual(captured.first?.1?.name, "Notes")

        pasteboard.clearContents(); pasteboard.setString("mine", forType: .string)
        monitor.ignore(changeCount: pasteboard.changeCount)
        XCTAssertFalse(monitor.checkNow())
        XCTAssertEqual(captured.count, 1)
    }

    func testMonitorRespectsPauseAndPrivacy() {
        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        var count = 0
        monitor.onCapture = { _, _ in count += 1 }
        monitor.isPaused = { true }
        pasteboard.clearContents(); pasteboard.setString("paused", forType: .string)
        XCTAssertFalse(monitor.checkNow())

        monitor.isPaused = { false }
        monitor.source = { AppSource(bundleID: "com.bitwarden.desktop", name: "Bitwarden") }
        pasteboard.clearContents(); pasteboard.setString("secret", forType: .string)
        XCTAssertFalse(monitor.checkNow())

        monitor.source = { nil }
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.TransientType")], owner: nil)
        pasteboard.setString("transient", forType: .string)
        XCTAssertFalse(monitor.checkNow())
        XCTAssertEqual(count, 0)
    }

    func testReadPrefersTextOverOfficePictureButImageOverURL() {
        let image = png()
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("Quarterly numbers", forType: .string)
        pasteboard.setData(image, forType: .png)
        XCTAssertEqual(ClipboardMonitor.read(pasteboard, options: CaptureOptions()), .text("Quarterly numbers"))

        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .png], owner: nil)
        pasteboard.setString("https://example.com/cat.png", forType: .string)
        pasteboard.setData(image, forType: .png)
        XCTAssertEqual(ClipboardMonitor.read(pasteboard, options: CaptureOptions()), .image(image))
        XCTAssertEqual(ClipboardMonitor.read(pasteboard, options: CaptureOptions(images: false)), .text("https://example.com/cat.png"))
    }

    func testReadFilesAndBlank() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nc-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        guard case .files(let urls) = ClipboardMonitor.read(pasteboard, options: CaptureOptions()) else {
            return XCTFail("expected files")
        }
        XCTAssertEqual(urls.map { $0.resolvingSymlinksInPath().path }, [url.resolvingSymlinksInPath().path])

        pasteboard.clearContents(); pasteboard.setString("   \n", forType: .string)
        XCTAssertNil(ClipboardMonitor.read(pasteboard, options: CaptureOptions()))
    }

    func testWriterRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = ImageStore(directory: dir)
        let now = Date()

        XCTAssertTrue(PasteboardWriter.write(ClipItem.fromText("hello", at: now)!, images: images, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "hello")

        XCTAssertTrue(PasteboardWriter.write(ClipItem.fromText("https://apple.com", at: now)!, images: images, to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "https://apple.com")
        XCTAssertEqual(pasteboard.string(forType: .URL), "https://apple.com")

        let data = png()
        let hash = ContentHash.forImage(data)
        let name = try images.save(pngData: data, hash: hash)
        let image = ClipItem.fromImage(fileName: name, hash: hash, width: 8, height: 6, at: now)
        XCTAssertTrue(PasteboardWriter.write(image, images: images, to: pasteboard))
        XCTAssertEqual(pasteboard.data(forType: .png), data)
        XCTAssertNotNil(pasteboard.data(forType: .tiff))

        let missing = ClipItem.fromFiles(["/nonexistent/\(UUID().uuidString)"], at: now)!
        XCTAssertFalse(PasteboardWriter.write(missing, images: images, to: pasteboard))
    }
}

final class ImageTests: XCTestCase {
    func testNormalizeKeepsPNGAndConvertsTIFF() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 4, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let normalizedPNG = try XCTUnwrap(ImageCodec.normalize(png))
        XCTAssertEqual(normalizedPNG.png, png)
        XCTAssertEqual(normalizedPNG.width, 10)
        XCTAssertEqual(normalizedPNG.height, 4)

        let tiff = try XCTUnwrap(rep.tiffRepresentation)
        let normalizedTIFF = try XCTUnwrap(ImageCodec.normalize(tiff))
        XCTAssertTrue(ImageCodec.isPNG(normalizedTIFF.png))
        XCTAssertEqual(normalizedTIFF.width, 10)

        XCTAssertNil(ImageCodec.normalize(Data("not an image".utf8)))
        XCTAssertNil(ImageCodec.normalize(Data()))
    }

    func testImageStoreSaveThumbnailDeleteOrphans() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ImageStore(directory: dir)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 600, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let hash = ContentHash.forImage(png)
        let name = try store.save(pngData: png, hash: hash)
        XCTAssertEqual(try store.save(pngData: png, hash: hash), name, "saving again is idempotent")
        XCTAssertTrue(store.exists(name))
        let thumb = try XCTUnwrap(store.thumbnail(name, maxPixel: 300))
        XCTAssertLessThanOrEqual(max(thumb.size.width, thumb.size.height), 300)

        try Data("x".utf8).write(to: dir.appendingPathComponent("orphan.png"))
        store.removeOrphans(keeping: [name])
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("orphan.png").path))
        XCTAssertTrue(store.exists(name))
        store.delete(name)
        XCTAssertFalse(store.exists(name))
    }
}

@MainActor
final class AppControllerTests: XCTestCase {
    var paths: AppPaths!
    var defaults: UserDefaults!
    var suite: String!
    var pasteboard: NSPasteboard!

    override func setUp() async throws {
        paths = AppPaths.temporary()
        suite = "NotchClipTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "fetchLinkTitles")
        defaults.set(false, forKey: "recognizeText")
        pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchClipTests.\(UUID().uuidString)"))
    }

    override func tearDown() async throws {
        pasteboard.releaseGlobally()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: paths.root)
    }

    func makeController() -> AppController {
        AppController(paths: paths, defaults: defaults, pasteboard: pasteboard, enableUI: false)
    }

    func png(_ width: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 5, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testCaptureTextLinkFilesAndModelSync() {
        let app = makeController()
        app.handle(.text("note"), source: AppSource(bundleID: "com.apple.Notes", name: "Notes"))
        app.handle(.text("https://apple.com"), source: nil)
        app.handle(.files([URL(fileURLWithPath: "/tmp/a.txt")]), source: nil)
        XCTAssertEqual(app.store.items.map(\.kind), [.file, .link, .text])
        XCTAssertEqual(app.model.allItems.count, 3)
        XCTAssertNil(app.handle(.text("  "), source: nil))
        XCTAssertEqual(app.store.items.count, 3)
    }

    func testImagePipelineDedupesAndDeleteRemovesFile() async throws {
        let app = makeController()
        let data = png(7)
        await app.handle(.image(data), source: nil)?.value
        await app.handle(.image(data), source: AppSource(bundleID: "com.apple.Preview", name: "Preview"))?.value
        XCTAssertEqual(app.store.items.count, 1)
        let item = try XCTUnwrap(app.store.items.first)
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.sourceAppName, "Preview")
        let name = try XCTUnwrap(item.imageFileName)
        XCTAssertTrue(app.imageStore.exists(name))
        app.delete(item)
        XCTAssertTrue(app.store.items.isEmpty)
        XCTAssertFalse(app.imageStore.exists(name))
    }

    func testRetentionTrimRemovesImageFiles() async throws {
        defaults.set(10, forKey: "maxItems")
        let app = makeController()
        var names: [String] = []
        for width in 1...11 {
            await app.handle(.image(png(width)), source: nil)?.value
            if let name = app.store.items.first?.imageFileName { names.append(name) }
        }
        XCTAssertEqual(app.store.items.count, 10)
        XCTAssertFalse(app.imageStore.exists(names[0]), "oldest image file is deleted with its clip")
        XCTAssertTrue(app.imageStore.exists(names[10]))
    }

    func testCopyWritesPasteboardWithoutRecapturing() {
        let app = makeController()
        app.handle(.text("first"), source: nil)
        app.handle(.text("second"), source: nil)
        let first = app.store.items.last!
        app.copy(first)
        XCTAssertEqual(pasteboard.string(forType: .string), "first")
        XCTAssertEqual(app.store.items.first?.id, first.id, "copied clip moves to the front")
        XCTAssertEqual(app.store.items.first?.useCount, 1)
        XCTAssertFalse(app.monitor.checkNow())
        XCTAssertEqual(app.store.items.count, 2)
    }

    func testPrimaryPastesWhenTrustedAndCopiesOtherwise() async throws {
        let app = makeController()
        var pasted = 0, prompted = 0
        app.pasteHandler = { pasted += 1 }
        app.requestTrust = { prompted += 1 }
        app.handle(.text("x"), source: nil)
        let item = app.store.items[0]

        app.isTrusted = { true }
        app.performPrimary(item)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(pasted, 1)

        app.isTrusted = { false }
        app.performPrimary(item)
        app.performPrimary(item)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(pasted, 1)
        XCTAssertEqual(prompted, 1, "the permission prompt is shown once")
        XCTAssertEqual(pasteboard.string(forType: .string), "x")

        app.settings.pasteOnSelect = false
        app.isTrusted = { true }
        app.performPrimary(item)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(pasted, 1)
    }

    func testPinSurvivesRestartAndClear() {
        let app = makeController()
        app.handle(.text("keep me"), source: nil)
        app.handle(.text("temporary"), source: nil)
        let keep = app.store.items.first { $0.text == "keep me" }!
        app.togglePin(keep)
        app.flush()

        let reopened = makeController()
        XCTAssertEqual(reopened.store.items.count, 2)
        XCTAssertTrue(reopened.store.items.first { $0.text == "keep me" }!.isPinned)
        reopened.store.clearUnpinned()
        XCTAssertEqual(reopened.store.items.map(\.text), ["keep me"])
    }

    func testTextDrop() async {
        let app = makeController()
        await app.collectDrop([NSItemProvider(object: "dropped text" as NSString)])
        XCTAssertEqual(app.store.items.first?.text, "dropped text")
        XCTAssertEqual(app.store.items.first?.sourceAppName, "Dropped on notch")
    }

    func testPauseStopsCapture() {
        let app = makeController()
        app.togglePause()
        XCTAssertTrue(app.settings.isPaused)
        pasteboard.clearContents(); pasteboard.setString("while paused", forType: .string)
        XCTAssertFalse(app.monitor.checkNow())
        app.togglePause()
        pasteboard.clearContents(); pasteboard.setString("resumed", forType: .string)
        XCTAssertTrue(app.monitor.checkNow())
        XCTAssertEqual(app.store.items.map(\.text), ["resumed"])
    }

    func testSettingsPersist() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.hotKey, .optionCommandV)
        settings.hotKey = .controlOptionV
        settings.historyDays = 7
        settings.ignoredApps = ["com.example.app"]
        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.hotKey, .controlOptionV)
        XCTAssertEqual(again.retentionPolicy, RetentionPolicy(maxAgeDays: 7, maxItems: 300))
        XCTAssertTrue(again.privacyPolicy.shouldIgnore(typeIdentifiers: [], sourceBundleID: "com.example.app"))
        XCTAssertFalse(again.isFirstLaunch)
    }
}
