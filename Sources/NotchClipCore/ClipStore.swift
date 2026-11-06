import Foundation

/// How long and how much history is kept. Pinned items are never removed by this policy.
public struct RetentionPolicy: Equatable, Sendable {
    /// Unpinned items older than this many days are removed. `nil` keeps them forever.
    public var maxAgeDays: Int?
    /// At most this many unpinned items are kept; the least recently used go first.
    public var maxItems: Int

    public init(maxAgeDays: Int? = 30, maxItems: Int = 300) {
        self.maxAgeDays = maxAgeDays
        self.maxItems = max(1, maxItems)
    }
}

/// Where the history is persisted.
public protocol ClipStoreBacking: AnyObject {
    func load() throws -> [ClipItem]
    func save(_ items: [ClipItem]) throws
}

public final class InMemoryBacking: ClipStoreBacking {
    public private(set) var saved: [ClipItem]
    public private(set) var saveCount = 0
    public init(_ items: [ClipItem] = []) { saved = items }
    public func load() throws -> [ClipItem] { saved }
    public func save(_ items: [ClipItem]) throws { saved = items; saveCount += 1 }
}

/// A versioned JSON file, written atomically. A damaged file is moved aside instead of being lost.
public final class JSONFileBacking: ClipStoreBacking {
    private struct Envelope: Codable {
        var version: Int
        var items: [ClipItem]
    }

    public static let currentVersion = 1
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() throws -> [ClipItem] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            return try Self.decoder.decode(Envelope.self, from: data).items
        } catch {
            // Keep the unreadable file for inspection and start fresh rather than crashing.
            let backup = url.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            return []
        }
    }

    public func save(_ items: [ClipItem]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(Envelope(version: Self.currentVersion, items: items))
        try data.write(to: url, options: [.atomic])
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        // Reference-date seconds round-trip exactly; seconds since 1970 lose sub-microsecond precision.
        e.dateEncodingStrategy = .deferredToDate
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .deferredToDate
        return d
    }()
}

/// The clipboard history: ordered, de-duplicated and bounded by a retention policy.
///
/// Not thread-safe; the app uses it from the main thread only.
public final class ClipStore {
    public enum AddResult: Equatable {
        /// New content was added.
        case inserted(ClipItem)
        /// The same content already existed and was moved to the top.
        case refreshed(ClipItem)
    }

    /// Most recently used first.
    public private(set) var items: [ClipItem]
    public var policy: RetentionPolicy {
        didSet { if policy != oldValue { applyRetention() } }
    }
    /// Called after every change to `items`.
    public var onChange: (() -> Void)?
    /// Called with items that left the history (deleted, expired or trimmed), so their files can be removed.
    public var onRemove: (([ClipItem]) -> Void)?

    private let backing: ClipStoreBacking
    private let now: () -> Date
    public private(set) var lastSaveError: Error?

    public init(backing: ClipStoreBacking, policy: RetentionPolicy = RetentionPolicy(), now: @escaping () -> Date = Date.init) {
        self.backing = backing
        self.policy = policy
        self.now = now
        let loaded = (try? backing.load()) ?? []
        // Defensive: drop duplicate ids/hashes that could only come from a hand-edited file.
        var seenIDs = Set<UUID>(), seenHashes = Set<String>()
        self.items = loaded
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .filter { seenIDs.insert($0.id).inserted && seenHashes.insert($0.contentHash).inserted }
        applyRetention(notify: false)
    }

    // MARK: Queries

    public func item(id: UUID) -> ClipItem? { items.first { $0.id == id } }
    public func item(hash: String) -> ClipItem? { items.first { $0.contentHash == hash } }
    public var pinnedItems: [ClipItem] { items.filter(\.isPinned) }

    // MARK: Mutations

    /// Adds content, or refreshes the existing entry with the same content (keeping its pin, title and OCR text).
    @discardableResult
    public func add(_ item: ClipItem) -> AddResult {
        if let index = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            var existing = items.remove(at: index)
            existing.lastUsedAt = now()
            if item.sourceBundleID != nil {
                existing.sourceBundleID = item.sourceBundleID
                existing.sourceAppName = item.sourceAppName
            }
            items.insert(existing, at: 0)
            changed()
            return .refreshed(existing)
        }
        var fresh = item
        fresh.lastUsedAt = max(fresh.lastUsedAt, fresh.createdAt)
        items.insert(fresh, at: 0)
        applyRetention(notify: false)
        changed()
        return .inserted(fresh)
    }

    /// Moves an item to the top and counts the use (after copy or paste).
    public func markUsed(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastUsedAt = now()
        item.useCount += 1
        items.insert(item, at: 0)
        changed()
    }

    public func setPinned(_ pinned: Bool, id: UUID) {
        update(id: id) { $0.isPinned = pinned }
        if !pinned { applyRetention() }
    }

    public func togglePin(id: UUID) {
        guard let item = item(id: id) else { return }
        setPinned(!item.isPinned, id: id)
    }

    /// Edits an item in place without changing its position.
    public func update(id: UUID, _ mutate: (inout ClipItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[index]
        let originalID = item.id
        mutate(&item)
        guard item.id == originalID, item != items[index] else { return }
        items[index] = item
        changed()
    }

    public func delete(ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        onRemove?(removed)
        changed()
    }

    /// Removes every unpinned item.
    public func clearUnpinned() {
        let removed = items.filter { !$0.isPinned }
        guard !removed.isEmpty else { return }
        items.removeAll { !$0.isPinned }
        onRemove?(removed)
        changed()
    }

    /// Removes expired and excess unpinned items.
    public func applyRetention() { applyRetention(notify: true) }

    private func applyRetention(notify: Bool) {
        var removed: [ClipItem] = []
        if let days = policy.maxAgeDays, days > 0 {
            let cutoff = now().addingTimeInterval(-Double(days) * 86_400)
            removed += items.filter { !$0.isPinned && $0.lastUsedAt < cutoff }
            items.removeAll { !$0.isPinned && $0.lastUsedAt < cutoff }
        }
        let unpinned = items.filter { !$0.isPinned }
        if unpinned.count > policy.maxItems {
            // `items` is ordered most recent first, so the tail is the least recently used.
            let excess = Set(unpinned.suffix(unpinned.count - policy.maxItems).map(\.id))
            removed += items.filter { excess.contains($0.id) }
            items.removeAll { excess.contains($0.id) }
        }
        guard !removed.isEmpty else { return }
        onRemove?(removed)
        if notify { changed() }
    }

    // MARK: Persistence

    /// Writes the history to its backing store.
    @discardableResult
    public func persist() -> Bool {
        do {
            try backing.save(items)
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = error
            return false
        }
    }

    private func changed() { onChange?() }
}
