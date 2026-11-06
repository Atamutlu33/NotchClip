import XCTest
@testable import NotchClipCore

final class ClassifierTests: XCTestCase {
    func testLinks() {
        XCTAssertEqual(ClipClassifier.kind(forText: "https://apple.com"), .link)
        XCTAssertEqual(ClipClassifier.kind(forText: "  http://example.org/path?q=1#x \n"), .link)
        XCTAssertEqual(ClipClassifier.kind(forText: "www.github.com/Atamutlu33"), .link)
        XCTAssertEqual(ClipClassifier.linkURL(from: "www.github.com")?.absoluteString, "https://www.github.com")
        XCTAssertEqual(ClipClassifier.kind(forText: "http://localhost:3000"), .link)
    }

    func testNotLinks() {
        XCTAssertEqual(ClipClassifier.kind(forText: "see https://apple.com for more"), .text)
        XCTAssertEqual(ClipClassifier.kind(forText: "ftp://files.example.com"), .text)
        XCTAssertEqual(ClipClassifier.kind(forText: "mailto:a@b.com"), .text)
        XCTAssertEqual(ClipClassifier.kind(forText: "https://nohost"), .text)
        XCTAssertEqual(ClipClassifier.kind(forText: "hello"), .text)
        XCTAssertEqual(ClipClassifier.kind(forText: "https://a.com\nhttps://b.com"), .text)
        XCTAssertEqual(ClipClassifier.kind(forText: "javascript:alert(1)"), .text)
    }

    func testFromTextRejectsBlank() {
        XCTAssertNil(ClipItem.fromText("   \n\t", at: Date()))
        XCTAssertNil(ClipItem.fromText("", at: Date()))
    }

    func testLinkTextIsTrimmedAndTextIsKeptVerbatim() {
        let link = ClipItem.fromText("  https://apple.com \n", at: Date())!
        XCTAssertEqual(link.text, "https://apple.com")
        XCTAssertEqual(link.url?.host, "apple.com")
        let text = ClipItem.fromText("  indented\n", at: Date())!
        XCTAssertEqual(text.text, "  indented\n")
    }

    func testHashesDifferByKind() {
        XCTAssertNotEqual(ContentHash.forText("a"), ContentHash.forFiles(["a"]))
        XCTAssertEqual(ContentHash.forText("same"), ContentHash.forText("same"))
        XCTAssertEqual(ContentHash.sha256(Data("abc".utf8)),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class FormattingTests: XCTestCase {
    func testSingleLine() {
        XCTAssertEqual(ClipFormatting.singleLine("a\n\n  b\tc", limit: 50), "a b c")
        XCTAssertEqual(ClipFormatting.singleLine("abcdef", limit: 4), "abc…")
    }

    func testFoldTurkish() {
        XCTAssertEqual(ClipFormatting.fold("ÇALIŞMA Iğdır İstanbul"), "calisma igdir istanbul")
    }

    func testDisplayTitles() {
        let d = Date()
        XCTAssertEqual(ClipItem.fromFiles(["/tmp/a.txt", "/tmp/b.txt"], at: d)!.displayTitle, "a.txt +1")
        XCTAssertEqual(ClipItem.fromImage(fileName: "x.png", hash: "i:x", width: 10, height: 20, at: d).displayTitle, "Image 10×20")
        var link = ClipItem.fromText("https://apple.com/mac", at: d)!
        XCTAssertEqual(link.displayTitle, "apple.com")
        link.linkTitle = "Mac - Apple"
        XCTAssertEqual(link.displayTitle, "Mac - Apple")
    }
}

final class StoreTests: XCTestCase {
    var clock = Date(timeIntervalSince1970: 1_000_000)

    func makeStore(_ backing: InMemoryBacking = InMemoryBacking(), policy: RetentionPolicy = RetentionPolicy()) -> ClipStore {
        ClipStore(backing: backing, policy: policy, now: { [unowned self] in self.clock })
    }

    func text(_ s: String) -> ClipItem { ClipItem.fromText(s, at: clock)! }

    func tick(_ seconds: TimeInterval = 1) { clock = clock.addingTimeInterval(seconds) }

    func testInsertOrderIsMostRecentFirst() {
        let store = makeStore()
        store.add(text("one")); tick()
        store.add(text("two")); tick()
        store.add(text("three"))
        XCTAssertEqual(store.items.map(\.text), ["three", "two", "one"])
    }

    func testDuplicateMovesToTopAndKeepsMetadata() {
        let store = makeStore()
        let first = text("same")
        store.add(first); tick()
        store.add(text("other")); tick()
        store.setPinned(true, id: first.id)
        store.update(id: first.id) { $0.recognizedText = "keep" }

        var again = text("same")
        again.sourceAppName = "Notes"; again.sourceBundleID = "com.apple.Notes"
        let result = store.add(again)

        guard case .refreshed(let refreshed) = result else { return XCTFail("expected refresh") }
        XCTAssertEqual(refreshed.id, first.id)
        XCTAssertEqual(store.items.count, 2)
        XCTAssertEqual(store.items.first?.id, first.id)
        XCTAssertTrue(store.items.first!.isPinned)
        XCTAssertEqual(store.items.first?.recognizedText, "keep")
        XCTAssertEqual(store.items.first?.sourceAppName, "Notes")
        XCTAssertEqual(store.items.first?.lastUsedAt, clock)
    }

    func testMarkUsed() {
        let store = makeStore()
        let a = text("a"); store.add(a); tick()
        store.add(text("b")); tick()
        store.markUsed(id: a.id)
        XCTAssertEqual(store.items.first?.id, a.id)
        XCTAssertEqual(store.items.first?.useCount, 1)
        store.markUsed(id: UUID()) // unknown id is ignored
        XCTAssertEqual(store.items.count, 2)
    }

    func testMaxItemsTrimsOldestUnpinnedOnly() {
        var removed: [ClipItem] = []
        let store = makeStore(policy: RetentionPolicy(maxAgeDays: nil, maxItems: 2))
        store.onRemove = { removed += $0 }
        let pinned = text("pinned"); store.add(pinned); store.setPinned(true, id: pinned.id); tick()
        store.add(text("a")); tick()
        store.add(text("b")); tick()
        store.add(text("c"))
        XCTAssertEqual(Set(store.items.compactMap(\.text)), ["pinned", "b", "c"])
        XCTAssertEqual(removed.map(\.text), ["a"])
    }

    func testAgeRetention() {
        let store = makeStore(policy: RetentionPolicy(maxAgeDays: 7, maxItems: 100))
        let old = text("old"); store.add(old)
        let oldPinned = text("old pinned"); store.add(oldPinned); store.setPinned(true, id: oldPinned.id)
        tick(8 * 86_400)
        store.add(text("new"))
        store.applyRetention()
        XCTAssertEqual(Set(store.items.compactMap(\.text)), ["old pinned", "new"])
    }

    func testUnpinningAppliesRetention() {
        let store = makeStore(policy: RetentionPolicy(maxAgeDays: nil, maxItems: 1))
        let a = text("a"); store.add(a); store.setPinned(true, id: a.id); tick()
        store.add(text("b"))
        XCTAssertEqual(store.items.count, 2)
        store.togglePin(id: a.id)
        XCTAssertEqual(store.items.compactMap(\.text), ["b"])
    }

    func testDeleteAndClear() {
        var removed = 0
        let store = makeStore()
        store.onRemove = { removed += $0.count }
        let a = text("a"); store.add(a)
        let b = text("b"); store.add(b); store.setPinned(true, id: b.id)
        store.add(text("c"))
        store.delete(ids: [a.id])
        XCTAssertEqual(store.items.count, 2)
        store.clearUnpinned()
        XCTAssertEqual(store.items.map(\.id), [b.id])
        XCTAssertEqual(removed, 2)
    }

    func testOnChangeFires() {
        var changes = 0
        let store = makeStore()
        store.onChange = { changes += 1 }
        let a = text("a")
        store.add(a)
        store.update(id: a.id) { $0.linkTitle = "x" }
        store.update(id: a.id) { $0.linkTitle = "x" } // no-op
        XCTAssertEqual(changes, 2)
    }

    func testPersistenceRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let store = ClipStore(backing: JSONFileBacking(url: url), now: { [unowned self] in self.clock })
        let a = text("hello"); store.add(a); store.setPinned(true, id: a.id); tick()
        store.add(ClipItem.fromImage(fileName: "i.png", hash: "i:1", width: 3, height: 4, at: clock)); tick()
        store.add(ClipItem.fromFiles(["/tmp/x"], at: clock)!)
        XCTAssertTrue(store.persist())

        let reloaded = ClipStore(backing: JSONFileBacking(url: url), now: { [unowned self] in self.clock })
        XCTAssertEqual(reloaded.items, store.items)
    }

    func testRealDatesRoundTripExactly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        let store = ClipStore(backing: JSONFileBacking(url: url))
        for text in ["a", "b", "c"] { store.add(ClipItem.fromText(text, at: Date())!) }
        XCTAssertTrue(store.persist())
        XCTAssertEqual(ClipStore(backing: JSONFileBacking(url: url)).items, store.items)
    }

    func testCorruptFileIsMovedAside() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.json")
        try Data("{not json".utf8).write(to: url)
        let store = ClipStore(backing: JSONFileBacking(url: url))
        XCTAssertTrue(store.items.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(names.contains { $0.contains("corrupt") })
    }

    func testLoadDropsDuplicatesAndSorts() {
        let a = ClipItem.fromText("a", at: clock)!
        var aCopy = ClipItem.fromText("a", at: clock.addingTimeInterval(-5))!
        aCopy.lastUsedAt = clock.addingTimeInterval(-5)
        let b = ClipItem.fromText("b", at: clock.addingTimeInterval(10))!
        let store = makeStore(InMemoryBacking([aCopy, a, b]))
        XCTAssertEqual(store.items.compactMap(\.text), ["b", "a"])
    }
}

final class SearchTests: XCTestCase {
    let d = Date()

    func items() -> [ClipItem] {
        var link = ClipItem.fromText("https://github.com/Atamutlu33/knock", at: d)!
        link.linkTitle = "Knock repository"
        var image = ClipItem.fromImage(fileName: "a.png", hash: "i:a", width: 1, height: 1, at: d)
        image.recognizedText = "Fatura Toplamı 1.250 TL"
        var text = ClipItem.fromText("Merhaba dünya, toplantı saat 3'te", at: d)!
        text.sourceAppName = "Slack"
        let file = ClipItem.fromFiles(["/Users/ata/Desktop/Report-Q3.pdf"], at: d)!
        var pinned = ClipItem.fromText("git push origin main", at: d)!
        pinned.isPinned = true
        return [link, image, text, file, pinned]
    }

    func testEmptyQueryReturnsFilteredInOrder() {
        let all = items()
        XCTAssertEqual(ClipSearch.results(in: all, query: "  ", filter: .all).count, 5)
        XCTAssertEqual(ClipSearch.results(in: all, query: "", filter: .images).map(\.kind), [.image])
        XCTAssertEqual(ClipSearch.results(in: all, query: "", filter: .links).count, 1)
        XCTAssertEqual(ClipSearch.results(in: all, query: "", filter: .files).count, 1)
        XCTAssertEqual(ClipSearch.results(in: all, query: "", filter: .text).count, 2)
        XCTAssertEqual(ClipSearch.results(in: all, query: "", filter: .pinned).map(\.text), ["git push origin main"])
    }

    func testMatchesEveryField() {
        let all = items()
        XCTAssertEqual(ClipSearch.results(in: all, query: "toplami", filter: .all).first?.kind, .image) // OCR + diacritics
        XCTAssertEqual(ClipSearch.results(in: all, query: "KNOCK repo", filter: .all).first?.kind, .link)
        XCTAssertEqual(ClipSearch.results(in: all, query: "github.com", filter: .all).first?.kind, .link)
        XCTAssertEqual(ClipSearch.results(in: all, query: "report", filter: .all).first?.kind, .file)
        XCTAssertEqual(ClipSearch.results(in: all, query: "slack", filter: .all).first?.text, "Merhaba dünya, toplantı saat 3'te")
        XCTAssertEqual(ClipSearch.results(in: all, query: "dunya", filter: .all).count, 1)
    }

    func testAllTokensMustMatch() {
        XCTAssertTrue(ClipSearch.results(in: items(), query: "merhaba zzz", filter: .all).isEmpty)
    }

    func testFuzzySubsequence() {
        XCTAssertEqual(ClipSearch.results(in: items(), query: "gpushm", filter: .all).first?.text, "git push origin main")
        // Short tokens must be substrings, avoiding noisy matches.
        XCTAssertTrue(ClipSearch.results(in: items(), query: "qz", filter: .all).isEmpty)
    }

    func testSubstringOutranksFuzzy() {
        let d = Date()
        let fuzzy = ClipItem.fromText("m a i n t e n a n c e", at: d)!
        let exact = ClipItem.fromText("main branch", at: d)!
        let results = ClipSearch.results(in: [fuzzy, exact], query: "main", filter: .all)
        XCTAssertEqual(results.first?.id, exact.id)
    }

    func testFilterCycling() {
        XCTAssertEqual(ClipFilter.all.next(), .text)
        XCTAssertEqual(ClipFilter.pinned.next(), .all)
        XCTAssertEqual(ClipFilter.all.next(by: -1), .pinned)
    }
}

final class PrivacyTests: XCTestCase {
    func testMarkersAndApps() {
        let policy = PrivacyPolicy(extraIgnoredApps: ["com.example.secret"])
        XCTAssertTrue(policy.shouldIgnore(typeIdentifiers: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"], sourceBundleID: nil))
        XCTAssertTrue(policy.shouldIgnore(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleID: "com.1password.1password"))
        XCTAssertTrue(policy.shouldIgnore(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleID: "com.example.secret"))
        XCTAssertFalse(policy.shouldIgnore(typeIdentifiers: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari"))
    }
}

final class LinkPrivacyAndAgeTests: XCTestCase {
    func testSafeToFetch() {
        XCTAssertTrue(LinkPrivacy.isSafeToFetch(URL(string: "https://www.apple.com/mac?ref=nav")!))
        XCTAssertFalse(LinkPrivacy.isSafeToFetch(URL(string: "http://localhost:3000")!))
        XCTAssertFalse(LinkPrivacy.isSafeToFetch(URL(string: "http://192.168.1.10/admin")!))
        XCTAssertFalse(LinkPrivacy.isSafeToFetch(URL(string: "http://172.20.0.1")!))
        XCTAssertFalse(LinkPrivacy.isSafeToFetch(URL(string: "https://printer.local")!))
        XCTAssertFalse(LinkPrivacy.isSafeToFetch(URL(string: "https://x.com/reset?token=abc")!))
        XCTAssertFalse(LinkPrivacy.isSafeToFetch(URL(string: "https://x.com/cb?client_secret=abc")!))
        XCTAssertFalse(LinkPrivacy.isSafeToFetch(URL(string: "https://user:pw@x.com")!))
        XCTAssertTrue(LinkPrivacy.isSafeToFetch(URL(string: "http://8.8.8.8")!))
    }

    func testShortAge() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertEqual(ClipFormatting.shortAge(from: now.addingTimeInterval(-5), to: now), "now")
        XCTAssertEqual(ClipFormatting.shortAge(from: now.addingTimeInterval(-300), to: now), "5m")
        XCTAssertEqual(ClipFormatting.shortAge(from: now.addingTimeInterval(-7_200), to: now), "2h")
        XCTAssertEqual(ClipFormatting.shortAge(from: now.addingTimeInterval(-3 * 86_400), to: now), "3d")
        XCTAssertEqual(ClipFormatting.shortAge(from: now.addingTimeInterval(-21 * 86_400), to: now), "3w")
        XCTAssertEqual(ClipFormatting.shortAge(from: now.addingTimeInterval(60), to: now), "now")
    }

    func testLooksLikeCode() {
        XCTAssertTrue(ClipFormatting.looksLikeCode("func a() {\n  return b[0];\n}"))
        XCTAssertFalse(ClipFormatting.looksLikeCode("Toplantı yarın saat üçte, unutma."))
    }
}
