import AppKit
import NotchClipCore

/// What the shelf can ask the app to do.
@MainActor
public protocol ShelfActions: AnyObject {
    /// Click or Return: paste into the previous app (or copy, depending on settings).
    func performPrimary(_ item: ClipItem)
    /// ⌘C: copy and keep the shelf open.
    func copy(_ item: ClipItem)
    func togglePin(_ item: ClipItem)
    func delete(_ item: ClipItem)
    /// Opens a link in the browser or reveals files in Finder.
    func open(_ item: ClipItem)
    /// ⌘S: save to the Desktop.
    func save(_ item: ClipItem)
    /// Choose a location to save.
    func saveAs(_ item: ClipItem)
    func dragProvider(for item: ClipItem) -> NSItemProvider
    func ingestDrop(_ providers: [NSItemProvider]) -> Bool
    func collapseShelf()
    func openSettings()
    func togglePause()
}

/// Sizes used to draw the notch and the shelf.
public struct ShelfLayout: Equatable {
    public var notchSize: CGSize
    public var hasNotch: Bool
    public var shelfWidth: CGFloat
    public static let contentHeight: CGFloat = 214
    public static let previewHeight: CGFloat = 250
    /// Transparent room around the shelf so its shadow is not clipped.
    public static let margin: CGFloat = 24

    public init(notchSize: CGSize = CGSize(width: 200, height: 32), hasNotch: Bool = true, shelfWidth: CGFloat = 720) {
        self.notchSize = notchSize
        self.hasNotch = hasNotch
        self.shelfWidth = shelfWidth
    }

    /// The space under the camera housing that content must avoid.
    public var topInset: CGFloat { hasNotch ? notchSize.height : 6 }

    public func shelfSize(previewing: Bool) -> CGSize {
        CGSize(width: shelfWidth, height: topInset + Self.contentHeight + (previewing ? Self.previewHeight : 0))
    }

    /// Window size while expanded: the shelf plus shadow margins on the sides and bottom.
    public func expandedWindowSize(previewing: Bool) -> CGSize {
        let shelf = shelfSize(previewing: previewing)
        return CGSize(width: shelf.width + Self.margin * 2, height: shelf.height + Self.margin)
    }

    /// Computes the layout for a screen. Pure, so it is unit-tested.
    public static func make(screenFrame: CGRect, safeAreaTop: CGFloat, leftAuxWidth: CGFloat?, rightAuxWidth: CGFloat?) -> ShelfLayout {
        let shelfWidth = min(760, max(420, screenFrame.width - 48))
        if safeAreaTop > 0, let left = leftAuxWidth, let right = rightAuxWidth {
            let notchWidth = max(120, screenFrame.width - left - right)
            return ShelfLayout(notchSize: CGSize(width: notchWidth, height: safeAreaTop), hasNotch: true, shelfWidth: shelfWidth)
        }
        // No notch: an invisible hot zone along the top edge of the screen.
        return ShelfLayout(notchSize: CGSize(width: 280, height: 6), hasNotch: false, shelfWidth: shelfWidth)
    }

    public func collapsedFrame(in screenFrame: CGRect) -> CGRect {
        CGRect(x: (screenFrame.midX - notchSize.width / 2).rounded(),
               y: screenFrame.maxY - notchSize.height,
               width: notchSize.width, height: notchSize.height)
    }

    public func expandedFrame(in screenFrame: CGRect, previewing: Bool) -> CGRect {
        let size = expandedWindowSize(previewing: previewing)
        return CGRect(x: (screenFrame.midX - size.width / 2).rounded(),
                      y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }
}

public struct Toast: Equatable, Identifiable {
    public let id = UUID()
    public var text: String
    public var symbol: String
}

/// State of the notch shelf: results, selection, preview and transient feedback.
@MainActor
public final class ShelfModel: ObservableObject {
    @Published public private(set) var allItems: [ClipItem] = []
    @Published public private(set) var results: [ClipItem] = []
    @Published public var query = "" {
        didSet { if query != oldValue { recompute(resetSelection: true) } }
    }
    @Published public var filter: ClipFilter = .all {
        didSet { if filter != oldValue { recompute(resetSelection: true) } }
    }
    @Published public var selectedID: UUID?
    @Published public var isPreviewing = false
    @Published public var isExpanded = false
    @Published public var isDropTargeted = false
    @Published public var isPaused = false
    @Published public var layout = ShelfLayout()
    @Published public private(set) var toast: Toast?
    /// Incremented to move keyboard focus into the search field.
    @Published public private(set) var focusSearchToken = 0

    public weak var actions: ShelfActions?
    public let imageStore: ImageStore
    /// Maximum number of cards rendered; search covers everything.
    public static let visibleLimit = 300

    private var toastTask: Task<Void, Never>?

    public init(imageStore: ImageStore) {
        self.imageStore = imageStore
    }

    public var selectedItem: ClipItem? {
        guard let selectedID else { return nil }
        return results.first { $0.id == selectedID }
    }

    public var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return results.firstIndex { $0.id == selectedID }
    }

    public var visibleResults: ArraySlice<ClipItem> { results.prefix(Self.visibleLimit) }

    public func setItems(_ items: [ClipItem]) {
        allItems = items
        recompute(resetSelection: false)
    }

    /// Called whenever the shelf opens: fresh search, first item selected.
    public func prepareForOpening() {
        query = ""
        filter = .all
        isPreviewing = false
        selectedID = results.first?.id
    }

    public func requestSearchFocus() { focusSearchToken &+= 1 }

    public func moveSelection(by delta: Int) {
        guard !results.isEmpty else { selectedID = nil; return }
        let current = selectedIndex ?? (delta > 0 ? -1 : results.count)
        let next = min(max(current + delta, 0), min(results.count, Self.visibleLimit) - 1)
        selectedID = results[next].id
    }

    public func selectFirst() { selectedID = results.first?.id }

    public func selectLast() {
        guard !results.isEmpty else { return }
        selectedID = results[min(results.count, Self.visibleLimit) - 1].id
    }

    public func item(atVisibleIndex index: Int) -> ClipItem? {
        index >= 0 && index < results.count ? results[index] : nil
    }

    public func showToast(_ text: String, symbol: String = "checkmark.circle.fill", duration: TimeInterval = 1.4) {
        toastTask?.cancel()
        toast = Toast(text: text, symbol: symbol)
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    private func recompute(resetSelection: Bool) {
        let previousIndex = selectedIndex
        results = ClipSearch.results(in: allItems, query: query, filter: filter)
        if resetSelection {
            selectedID = results.first?.id
        } else if selectedID == nil || !results.contains(where: { $0.id == selectedID }) {
            // The selected item went away (deleted or expired): select its neighbour.
            if results.isEmpty {
                selectedID = nil
            } else {
                selectedID = results[min(previousIndex ?? 0, results.count - 1)].id
            }
        }
        if results.isEmpty { isPreviewing = false }
    }
}
