import AppKit
import NotchClipCore

/// End-to-end check of the packaged app: `NotchClip.app/Contents/MacOS/NotchClip --self-test`.
///
/// Runs the real controller, window and services against a private pasteboard and a temporary
/// data folder, so it never touches the user's clipboard or history. Exit code 0 means every check passed.
@MainActor
public enum SelfTest {
    public static func run() async -> Int32 {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            print((condition ? "PASS  " : "FAIL  ") + message)
            if !condition { failures.append(message) }
        }

        let paths = AppPaths.temporary()
        let suiteName = "NotchClip.selftest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.set(false, forKey: "fetchLinkTitles")
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("NotchClip.selftest.\(UUID().uuidString)"))
        defer {
            pasteboard.releaseGlobally()
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: paths.root)
        }

        let system = InMemoryPreferences(["location": "/Users/selftest/Desktop"])
        let app = AppController(paths: paths, defaults: defaults, pasteboard: pasteboard, enableUI: true,
                                screenshotPreferences: system)
        var pasteCount = 0
        app.isTrusted = { true }
        app.pasteHandler = { pasteCount += 1 }
        app.requestTrust = {}
        app.start()

        // Text capture and de-duplication.
        pasteboard.clearContents()
        pasteboard.setString("Hello from the NotchClip self-test", forType: .string)
        app.monitor.checkNow()
        check(app.store.items.first?.text == "Hello from the NotchClip self-test", "captures copied text")
        pasteboard.clearContents()
        pasteboard.setString("Hello from the NotchClip self-test", forType: .string)
        app.monitor.checkNow()
        check(app.store.items.count == 1, "copying the same text again does not duplicate it")

        // Links.
        pasteboard.clearContents()
        pasteboard.setString("https://github.com/Atamutlu33/NotchClip", forType: .string)
        app.monitor.checkNow()
        check(app.store.items.first?.kind == .link, "classifies a copied URL as a link")

        // Secrets are skipped.
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pasteboard.setString("hunter2", forType: .string)
        app.monitor.checkNow()
        check(!app.store.items.contains { $0.text == "hunter2" }, "skips content marked as concealed")

        // Files.
        let fileURL = paths.root.appendingPathComponent("Report.txt")
        try? Data("report".utf8).write(to: fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        app.monitor.checkNow()
        check(app.store.items.first?.kind == .file && app.store.items.first?.filePaths == [fileURL.path], "captures copied files")

        // Images, including on-device text recognition.
        if let png = renderTestImage(text: "NOTCHCLIP 2026") {
            pasteboard.clearContents()
            pasteboard.setData(png, forType: .png)
            app.monitor.checkNow()
            let gotImage = await waitUntil(seconds: 10) { app.store.items.first?.kind == .image }
            check(gotImage, "captures a copied image")
            if let image = app.store.items.first, image.kind == .image, let name = image.imageFileName {
                check(app.imageStore.exists(name), "stores the image file")
                check(app.imageStore.thumbnail(name) != nil, "renders an image thumbnail")
                let recognized = await waitUntil(seconds: 30) {
                    app.store.item(id: image.id)?.recognizedText?.uppercased().contains("NOTCHCLIP") == true
                }
                check(recognized, "recognises text inside the image (OCR)")
            }
        } else {
            check(false, "could render a test image")
        }

        // Search.
        app.model.query = "self-test"
        check(app.model.results.count == 1 && app.model.results.first?.kind == .text, "search finds text")
        app.model.query = "notchclip 2026"
        check(app.model.results.first?.kind == .image, "search finds text inside images")
        app.model.query = ""

        // The notch window opens, handles keys and pastes.
        guard let window = app.windowController else {
            check(false, "creates the notch window")
            return finish(failures)
        }
        check(window.panel.isVisible, "notch window is on screen when collapsed")
        let collapsedHeight = window.panel.frame.height
        window.expand(reason: .keyboard)
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(app.model.isExpanded && window.panel.frame.height > collapsedHeight + 100, "shelf expands")
        check(app.model.selectedIndex == 0, "first clip is selected on open")
        _ = ShelfKeyHandler.handle(keyCode: ShelfKeyHandler.Key.right, command: false, shift: false,
                                   characters: "", model: app.model, collapse: {})
        check(app.model.selectedIndex == 1, "→ moves the selection")
        _ = ShelfKeyHandler.handle(keyCode: ShelfKeyHandler.Key.space, command: false, shift: false,
                                   characters: " ", model: app.model, collapse: {})
        try? await Task.sleep(nanoseconds: 400_000_000)
        check(app.model.isPreviewing && window.panel.frame.height > collapsedHeight + 300, "Space opens the preview")
        _ = ShelfKeyHandler.handle(keyCode: ShelfKeyHandler.Key.escape, command: false, shift: false,
                                   characters: "", model: app.model, collapse: {})
        check(!app.model.isPreviewing, "Esc closes the preview")

        let target = app.model.selectedItem
        if let target {
            app.performPrimary(target)
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(pasteCount == 1, "↩ pastes into the previous app")
            check(!app.model.isExpanded, "shelf closes after pasting")
            check(app.store.items.first?.id == target.id, "used clip moves to the front")
            let countBefore = app.store.items.count
            app.monitor.checkNow()
            check(app.store.items.count == countBefore, "the app's own copy is not recorded again")
        } else {
            check(false, "has a selected clip")
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        check(window.panel.frame.height <= collapsedHeight + 1, "window shrinks back to the notch")

        // Screenshots: routed to the inbox, put on the shelf and clipboard, never left on disk.
        check(system.value(forKey: "location") as? String == paths.screenshotInbox.path, "screenshots are redirected away from the Desktop")
        if let png = renderTestImage(text: "SCREENSHOT") {
            let shot = paths.screenshotInbox.appendingPathComponent("Screenshot 2026-11-06 at 12.00.00.png")
            try? png.write(to: shot)
            let arrived = await waitUntil(seconds: 10) { app.store.items.first?.sourceAppName == "Screenshot" }
            check(arrived, "a new screenshot appears on the shelf automatically")
            check(!FileManager.default.fileExists(atPath: shot.path), "the screenshot file is not kept on disk")
            check(pasteboard.data(forType: .png) == png, "the screenshot is copied to the clipboard")
            check(app.model.isExpanded && app.model.selectedIndex == 0, "the shelf shows the new screenshot")
            check(!window.panel.isKeyWindow, "showing it does not steal the keyboard")
            let saveDir = paths.root.appendingPathComponent("Saved", isDirectory: true)
            try? FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
            if let item = app.store.items.first, let saved = try? app.saveItem(item, to: saveDir).first {
                check(NSImage(contentsOf: saved) != nil, "you can save the screenshot when you decide to")
            } else {
                check(false, "you can save the screenshot when you decide to")
            }
            window.collapse(immediately: true)
        }

        // Pinning, persistence and deletion.
        if let first = app.store.items.first {
            app.togglePin(first)
            check(app.store.item(id: first.id)?.isPinned == true, "pins a clip")
        }
        app.flush()
        let reloaded = ClipStore(backing: JSONFileBacking(url: paths.history))
        check(reloaded.items == app.store.items, "history survives a restart")

        if let image = app.store.items.first(where: { $0.kind == .image }), let name = image.imageFileName {
            app.delete(image)
            check(!app.imageStore.exists(name), "deleting an image clip removes its file")
        }

        app.stop()
        check(system.value(forKey: "location") as? String == "/Users/selftest/Desktop", "quitting restores the screenshot location")
        return finish(failures)
    }

    private static func finish(_ failures: [String]) -> Int32 {
        print(failures.isEmpty ? "\nSELF-TEST PASSED" : "\nSELF-TEST FAILED (\(failures.count))")
        return failures.isEmpty ? 0 : 1
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return condition()
    }

    static func renderTestImage(text: String) -> Data? {
        let size = NSSize(width: 900, height: 220)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        (text as NSString).draw(at: NSPoint(x: 40, y: 70), withAttributes: [
            .font: NSFont.boldSystemFont(ofSize: 72),
            .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
