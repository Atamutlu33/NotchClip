import AppKit
import Combine
import SwiftUI
import NotchClipCore

/// A borderless panel that can take keyboard focus without activating the app,
/// so the app you were typing in stays frontmost and receives the paste.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Hosts the SwiftUI content and reports hover through a tracking area that works while the app is inactive.
final class NotchContainerView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch window: opening, closing, hover, keyboard and screen changes.
@MainActor
public final class NotchWindowController {
    public enum OpenReason { case hover, keyboard, drop, programmatic, peek }

    let panel: NotchPanel
    let model: ShelfModel
    private let container: NotchContainerView
    private var screenFrame: CGRect = .zero
    private var openReason: OpenReason?
    private var hoverWorkItem: DispatchWorkItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var peekWorkItem: DispatchWorkItem?
    private var isHovering = false
    private var keyMonitor: Any?
    private var clickMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var previewObservation: Any?
    private var dropObservation: Any?

    /// Whether hovering the notch opens the shelf.
    public var hoverEnabled: @MainActor () -> Bool = { true }
    /// Called when the shelf opens or closes.
    public var onVisibilityChange: ((Bool) -> Void)?

    public static let hoverDelay: TimeInterval = 0.12
    public static let collapseDelay: TimeInterval = 0.35
    /// How long the shelf stays down after a screenshot if you ignore it.
    public static let peekDuration: TimeInterval = 4
    static let animationDuration: TimeInterval = 0.32

    public init(model: ShelfModel) {
        self.model = model
        let panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32))
        let container = NotchContainerView(frame: panel.contentRect(forFrameRect: panel.frame))
        container.autoresizingMask = [.width, .height]

        let hosting = NSHostingView(rootView: NotchRootView(model: model))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        panel.contentView = container
        self.panel = panel
        self.container = container

        container.onHoverChange = { [weak self] inside in self?.hoverChanged(inside) }

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateGeometry() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
            })

        dropObservation = model.$isDropTargeted.removeDuplicates().sink { [weak self] targeted in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.dropTargetChanged(targeted) } }
        }
        previewObservation = model.$isPreviewing.dropFirst().sink { [weak self] previewing in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.resizeForPreview(previewing) } }
        }
    }

    public var isExpanded: Bool { model.isExpanded }

    /// Places the collapsed notch window on the screen with a notch (or the main screen).
    public func show() {
        updateGeometry()
        panel.orderFrontRegardless()
    }

    public func updateGeometry() {
        guard let screen = Self.preferredScreen() else { return }
        let left = screen.auxiliaryTopLeftArea?.width
        let right = screen.auxiliaryTopRightArea?.width
        screenFrame = screen.frame
        model.layout = ShelfLayout.make(screenFrame: screen.frame, safeAreaTop: screen.safeAreaInsets.top,
                                        leftAuxWidth: left, rightAuxWidth: right)
        applyFrame()
    }

    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private func applyFrame() {
        let frame = model.isExpanded
            ? model.layout.expandedFrame(in: screenFrame, previewing: model.isPreviewing)
            : model.layout.collapsedFrame(in: screenFrame)
        panel.setFrame(frame, display: true)
    }

    // MARK: Open / close

    public func toggle() {
        model.isExpanded ? collapse() : expand(reason: .keyboard)
    }

    public func expand(reason: OpenReason) {
        cancelTimers()
        if model.isExpanded {
            if reason == .keyboard { openReason = .keyboard; model.requestSearchFocus() }
            return
        }
        openReason = reason
        model.prepareForOpening()
        if screenFrame == .zero { updateGeometry() }
        model.isExpanded = true
        applyFrame()
        panel.orderFrontRegardless()
        if reason != .peek {
            // A peek must not steal the keyboard from the app you are typing in.
            panel.makeKey()
            model.requestSearchFocus()
        }
        installMonitors()
        onVisibilityChange?(true)
    }

    /// Shows the shelf briefly with one clip selected, without taking keyboard focus (used after a screenshot).
    /// Hovering or typing keeps it open; otherwise it tucks itself away.
    public func peek(selecting id: UUID?) {
        if !model.isExpanded { expand(reason: .peek) }
        if let id { model.selectedID = id }
        guard openReason == .peek else { return }
        peekWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.isExpanded, self.openReason == .peek, !self.isHovering else { return }
                if NSEvent.pressedMouseButtons != 0 { self.peek(selecting: nil); return }
                self.collapse()
            }
        }
        peekWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.peekDuration, execute: work)
    }

    public var currentOpenReason: OpenReason? { openReason }

    /// Closes the shelf. `immediately` skips the animation so focus returns to the previous app at once (used before pasting).
    public func collapse(immediately: Bool = false) {
        cancelTimers()
        guard model.isExpanded else { return }
        removeMonitors()
        openReason = nil
        model.isPreviewing = false
        model.isExpanded = false
        panel.makeFirstResponder(nil)
        // Ordering the key panel out hands keyboard focus back to the app underneath.
        panel.orderOut(nil)
        if immediately {
            finishCollapse()
        } else {
            // Re-show at full size for the closing animation without taking focus, then shrink.
            panel.setFrame(model.layout.expandedFrame(in: screenFrame, previewing: false), display: false)
            panel.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.animationDuration) { [weak self] in
                MainActor.assumeIsolated { self?.finishCollapse() }
            }
        }
        onVisibilityChange?(false)
    }

    private func finishCollapse() {
        guard !model.isExpanded else { return }
        applyFrame()
        panel.orderFrontRegardless()
    }

    private func resizeForPreview(_ previewing: Bool) {
        guard model.isExpanded else { return }
        let frame = model.layout.expandedFrame(in: screenFrame, previewing: previewing)
        if previewing || frame.height > panel.frame.height {
            panel.setFrame(frame, display: true)
        } else {
            // Shrink after the content has animated up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.model.isExpanded, !self.model.isPreviewing else { return }
                    self.panel.setFrame(frame, display: true)
                }
            }
        }
    }

    // MARK: Hover

    private func hoverChanged(_ inside: Bool) {
        isHovering = inside
        if inside, model.isExpanded, openReason == .peek {
            // The user came to look: behave like a normal hover-open from now on.
            peekWorkItem?.cancel()
            openReason = .hover
            panel.makeKey()
            model.requestSearchFocus()
        }
        if inside {
            collapseWorkItem?.cancel()
            guard !model.isExpanded, hoverEnabled() else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isHovering, !self.model.isExpanded else { return }
                    self.expand(reason: .hover)
                }
            }
            hoverWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverDelay, execute: work)
        } else {
            hoverWorkItem?.cancel()
            scheduleHoverCollapse()
        }
    }

    private func scheduleHoverCollapse() {
        guard model.isExpanded, openReason == .hover || openReason == .drop else { return }
        collapseWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hoverCollapseFired() }
        }
        collapseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.collapseDelay, execute: work)
    }

    private func hoverCollapseFired() {
        guard model.isExpanded, !isHovering else { return }
        // Never close under a drag, a search in progress, or keyboard use.
        if NSEvent.pressedMouseButtons != 0 || model.isDropTargeted {
            scheduleHoverCollapse()
            return
        }
        guard model.query.isEmpty, openReason == .hover || openReason == .drop else { return }
        collapse()
    }

    /// Dragging something over the collapsed notch opens it.
    public func dropTargetChanged(_ targeted: Bool) {
        if targeted, !model.isExpanded { expand(reason: .drop) }
    }

    private func cancelTimers() {
        hoverWorkItem?.cancel()
        collapseWorkItem?.cancel()
        peekWorkItem?.cancel()
    }

    // MARK: Event monitors

    private func installMonitors() {
        removeMonitors()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.isExpanded, event.window === self.panel else { return event }
            return self.handleKey(event) ? nil : event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
    }

    private func removeMonitors() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        keyMonitor = nil
        clickMonitor = nil
    }

    /// Returns true when the key was handled by the shelf.
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = flags.contains(.command)
        let shift = flags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        // Any keyboard use keeps the shelf open when the mouse leaves.
        openReason = .keyboard
        return ShelfKeyHandler.handle(keyCode: event.keyCode, command: command, shift: shift,
                                      characters: chars, model: model, collapse: { [weak self] in self?.collapse() })
    }
}

/// Keyboard behaviour of the open shelf, separated from AppKit events so it can be tested.
@MainActor
public enum ShelfKeyHandler {
    public enum Key {
        public static let escape: UInt16 = 53, left: UInt16 = 123, right: UInt16 = 124, down: UInt16 = 125, up: UInt16 = 126
        public static let returnKey: UInt16 = 36, keypadEnter: UInt16 = 76, tab: UInt16 = 48, space: UInt16 = 49
        public static let delete: UInt16 = 51, forwardDelete: UInt16 = 117, home: UInt16 = 115, end: UInt16 = 119
    }

    public static func handle(keyCode: UInt16, command: Bool, shift: Bool, characters: String,
                              model: ShelfModel, collapse: () -> Void) -> Bool {
        let actions = model.actions
        let selected = model.selectedItem

        switch keyCode {
        case Key.escape:
            if model.isPreviewing { model.isPreviewing = false }
            else if !model.query.isEmpty { model.query = "" }
            else { collapse() }
            return true
        case Key.left:
            if command { model.selectFirst() } else { model.moveSelection(by: -1) }
            return true
        case Key.right:
            if command { model.selectLast() } else { model.moveSelection(by: 1) }
            return true
        case Key.home:
            model.selectFirst(); return true
        case Key.end:
            model.selectLast(); return true
        case Key.down:
            if selected != nil { model.isPreviewing = true }
            return true
        case Key.up:
            model.isPreviewing = false
            return true
        case Key.returnKey, Key.keypadEnter:
            if let selected {
                if shift { actions?.copy(selected) } else { actions?.performPrimary(selected) }
            }
            return true
        case Key.tab:
            model.filter = model.filter.next(by: shift ? -1 : 1)
            return true
        case Key.space where model.query.isEmpty && !command:
            if selected != nil { model.isPreviewing.toggle() }
            return true
        case Key.delete where command, Key.forwardDelete where command:
            if let selected { actions?.delete(selected) }
            return true
        default:
            break
        }

        guard command else { return false }
        switch characters {
        case "c":
            if let selected { actions?.copy(selected) }
            return true
        case "p":
            if let selected { actions?.togglePin(selected) }
            return true
        case "o":
            if let selected { actions?.open(selected) }
            return true
        case "s":
            if let selected {
                if shift { actions?.saveAs(selected) } else { actions?.save(selected) }
            }
            return true
        case "y":
            if selected != nil { model.isPreviewing.toggle() }
            return true
        case ",":
            actions?.openSettings()
            return true
        case "f":
            model.requestSearchFocus()
            return true
        case "w":
            collapse()
            return true
        case "1", "2", "3", "4", "5", "6", "7", "8", "9":
            if let n = Int(characters), let item = model.item(atVisibleIndex: n - 1) {
                model.selectedID = item.id
                actions?.performPrimary(item)
            }
            return true
        default:
            // ⌘A, ⌘V, ⌘X, ⌘Z… belong to the search field.
            return false
        }
    }
}
