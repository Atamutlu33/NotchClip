import AppKit
import SwiftUI
import UniformTypeIdentifiers
import NotchClipCore

/// A notch outline: square top edge with optional concave "shoulders", rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = max(0, min(topRadius, rect.width / 4))
        let b = max(0, min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t), control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY), control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b), control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// Everything drawn in the notch window.
struct NotchRootView: View {
    @ObservedObject var model: ShelfModel

    private var shapeSize: CGSize {
        model.isExpanded ? model.layout.shelfSize(previewing: model.isPreviewing) : model.layout.notchSize
    }

    var body: some View {
        let expanded = model.isExpanded
        let visible = expanded || model.layout.hasNotch
        ZStack(alignment: .top) {
            NotchShape(topRadius: expanded ? 14 : 0, bottomRadius: expanded ? 24 : 10)
                // An almost transparent fill still receives the mouse on screens without a notch.
                .fill(Color.black.opacity(visible ? 1 : 0.004))
                .overlay(
                    NotchShape(topRadius: expanded ? 14 : 0, bottomRadius: expanded ? 24 : 10)
                        .stroke(Color.accentColor.opacity(model.isDropTargeted ? 0.9 : 0), lineWidth: 2)
                )
                .frame(width: shapeSize.width, height: shapeSize.height)
                .shadow(color: .black.opacity(expanded ? 0.45 : 0), radius: 14, y: 6)

            if expanded {
                ShelfView(model: model)
                    .padding(.horizontal, 14 + 10)
                    .frame(width: shapeSize.width, height: shapeSize.height, alignment: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.34, dampingFraction: 0.84), value: model.isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.86), value: model.isPreviewing)
        .onDrop(of: [.fileURL, .url, .image, .plainText, .utf8PlainText], isTargeted: $model.isDropTargeted) { providers in
            model.actions?.ingestDrop(providers) ?? false
        }
        .environment(\.colorScheme, .dark)
    }
}

struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: max(0, model.layout.topInset - 4))
            header
            if model.isPreviewing, let item = model.selectedItem {
                PreviewPane(item: item, imageStore: model.imageStore)
                    .frame(height: ShelfLayout.previewHeight - 10)
                    .transition(.opacity)
            }
            cards
            footer
        }
        .padding(.bottom, 10)
        .overlay(alignment: .bottom) { toastView }
        .onAppear { searchFocused = true }
        .onChange(of: model.focusSearchToken) { _, _ in searchFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(ClipFilter.allCases) { filter in
                Button { model.filter = filter } label: {
                    Text(filter.title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(model.filter == filter ? 0.18 : 0)))
                        .foregroundStyle(model.filter == filter ? Color.white : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 8)
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                TextField("Search", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.45))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(width: 210, height: 26)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            iconButton(model.isPaused ? "play.fill" : "pause.fill", help: model.isPaused ? "Resume capture" : "Pause capture") {
                model.actions?.togglePause()
            }
            iconButton("gearshape.fill", help: "Settings (⌘,)") { model.actions?.openSettings() }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.1)))
                .foregroundStyle(.white.opacity(0.75))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: Cards

    private var cards: some View {
        Group {
            if model.results.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 10) {
                            ForEach(Array(model.visibleResults.enumerated()), id: \.element.id) { index, item in
                                ClipCard(item: item, index: index, isSelected: item.id == model.selectedID,
                                         imageStore: model.imageStore)
                                    .id(item.id)
                                    .onTapGesture {
                                        model.selectedID = item.id
                                        model.actions?.performPrimary(item)
                                    }
                                    .onDrag { model.actions?.dragProvider(for: item) ?? NSItemProvider() }
                                    .contextMenu { contextMenu(for: item) }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onChange(of: model.selectedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .frame(height: 126)
    }

    @ViewBuilder
    private func contextMenu(for item: ClipItem) -> some View {
        Button("Paste") { model.actions?.performPrimary(item) }
        Button("Copy") { model.actions?.copy(item) }
        Button(item.isPinned ? "Unpin" : "Pin") { model.actions?.togglePin(item) }
        Button("Save to Desktop") { model.actions?.save(item) }
        Button("Save As…") { model.actions?.saveAs(item) }
        Button("Preview") { model.selectedID = item.id; model.isPreviewing = true }
        if item.kind == .link { Button("Open in Browser") { model.actions?.open(item) } }
        if item.kind == .file || item.kind == .image { Button("Show in Finder") { model.actions?.open(item) } }
        Divider()
        Button("Delete", role: .destructive) { model.actions?.delete(item) }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 22)).foregroundStyle(.white.opacity(0.35))
            Text(emptyTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            Text(emptySubtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if !model.query.isEmpty { return "No matches for “\(model.query)”" }
        if model.filter == .pinned { return "Nothing pinned yet" }
        return model.filter == .all ? "Your clipboard history lives here" : "No \(model.filter.title.lowercased()) yet"
    }

    private var emptySubtitle: String {
        if !model.query.isEmpty { return "Search covers text, links, file names and text inside images." }
        if model.filter == .pinned { return "Press ⌘P on any clip to keep it forever." }
        return "Copy anything, or drop files and images onto the notch."
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            hint("↩", "Paste"); hint("⌘C", "Copy"); hint("Space", "Preview")
            hint("⌘S", "Save"); hint("⌘P", "Pin"); hint("⌘⌫", "Delete")
            Spacer()
            if model.isPaused {
                Label("Capture paused", systemImage: "pause.circle.fill").foregroundStyle(.orange)
            } else {
                Text("\(model.results.count) of \(model.allItems.count)")
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.white.opacity(0.4))
        .lineLimit(1)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key).font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.1)))
            Text(label)
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Label(toast.text, systemImage: toast.symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.16)))
                .foregroundStyle(.white)
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .id(toast.id)
        }
    }
}

/// One history entry.
struct ClipCard: View {
    let item: ClipItem
    let index: Int
    let isSelected: Bool
    let imageStore: ImageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 4) {
                AppIcon(bundleID: item.sourceBundleID).frame(width: 12, height: 12)
                Text(ClipFormatting.shortAge(from: item.lastUsedAt, to: Date()))
                Spacer(minLength: 2)
                if item.isPinned {
                    Image(systemName: "pin.fill").foregroundStyle(.yellow)
                }
                if index < 9 {
                    Text("⌘\(index + 1)").fontWeight(.semibold)
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(8)
        .frame(width: 156, height: 120)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isSelected ? 0.16 : 0.07)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(isSelected ? Color.accentColor : Color.white.opacity(0.06), lineWidth: isSelected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help(item.displayTitle)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            let text = String((item.text ?? "").prefix(500))
            Text(text)
                .font(.system(size: 11, design: ClipFormatting.looksLikeCode(text) ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(6)
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                Label(item.url?.host ?? "Link", systemImage: "link")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                Text(item.linkTitle ?? item.text ?? "")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(4)
            }
        case .image:
            if let name = item.imageFileName, let image = imageStore.thumbnail(name) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Label("Image missing", systemImage: "photo").font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
            }
        case .file:
            HStack(alignment: .top, spacing: 8) {
                FileIcon(path: item.filePaths?.first).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.fileURLs.first?.lastPathComponent ?? "File")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                    if item.fileURLs.count > 1 {
                        Text("+\(item.fileURLs.count - 1) more").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
        }
    }
}

/// Large view of the selected item (Space).
struct PreviewPane: View {
    let item: ClipItem
    let imageStore: ImageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                switch item.kind {
                case .text:
                    ScrollView {
                        Text(item.text ?? "")
                            .font(.system(size: 12, design: ClipFormatting.looksLikeCode(item.text ?? "") ? .monospaced : .default))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                case .link:
                    VStack(alignment: .leading, spacing: 8) {
                        if let title = item.linkTitle { Text(title).font(.system(size: 15, weight: .semibold)) }
                        Text(item.text ?? "").font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                case .image:
                    HStack(spacing: 12) {
                        if let name = item.imageFileName, let image = imageStore.thumbnail(name, maxPixel: 1400) {
                            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        if let ocr = item.recognizedText {
                            ScrollView {
                                Text(ocr).font(.system(size: 11)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(width: 230)
                        }
                    }
                case .file:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(item.filePaths ?? [], id: \.self) { path in
                                HStack(spacing: 8) {
                                    FileIcon(path: path).frame(width: 22, height: 22)
                                    Text(path).font(.system(size: 11)).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                                    if !FileManager.default.fileExists(atPath: path) {
                                        Text("missing").font(.system(size: 10)).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(metadata).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).lineLimit(1)
        }
        .padding(12)
        .foregroundStyle(.white.opacity(0.92))
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    private var metadata: String {
        var parts: [String] = []
        if let app = item.sourceAppName { parts.append(app) }
        parts.append(item.createdAt.formatted(date: .abbreviated, time: .shortened))
        switch item.kind {
        case .text: parts.append("\((item.text ?? "").count) characters")
        case .image:
            if let w = item.imagePixelWidth, let h = item.imagePixelHeight { parts.append("\(w)×\(h) px") }
            if item.recognizedText != nil { parts.append("text recognised") }
        case .file: parts.append("\(item.fileURLs.count) item(s)")
        case .link: break
        }
        if item.useCount > 0 { parts.append("used \(item.useCount)×") }
        return parts.joined(separator: " · ")
    }
}

/// Icons are looked up once and cached.
@MainActor
enum IconCache {
    static var apps: [String: NSImage] = [:]
    static var files: [String: NSImage] = [:]

    static func app(_ bundleID: String) -> NSImage? {
        if let cached = apps[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        apps[bundleID] = icon
        return icon
    }

    static func file(_ path: String) -> NSImage {
        if let cached = files[path] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        if files.count > 500 { files.removeAll() }
        files[path] = icon
        return icon
    }
}

struct AppIcon: View {
    let bundleID: String?
    var body: some View {
        if let bundleID, let icon = IconCache.app(bundleID) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().foregroundStyle(.white.opacity(0.3))
        }
    }
}

struct FileIcon: View {
    let path: String?
    var body: some View {
        if let path {
            Image(nsImage: IconCache.file(path)).resizable()
        } else {
            Image(systemName: "doc").resizable().foregroundStyle(.white.opacity(0.5))
        }
    }
}
