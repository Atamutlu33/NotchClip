import AppKit
import Combine
import ServiceManagement
import SwiftUI
import NotchClipCore

/// Operations the settings window can trigger.
struct SettingsCommands {
    var clearHistory: () -> Void
    var openDataFolder: () -> Void
    var historyCount: () -> Int
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    let commands: SettingsCommands

    var body: some View {
        TabView {
            GeneralTab(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            CaptureTab(settings: settings)
                .tabItem { Label("Capture", systemImage: "doc.on.clipboard") }
            HistoryTab(settings: settings, commands: commands)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 430)
    }
}

private struct GeneralTab: View {
    @ObservedObject var settings: AppSettings
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    @State private var trusted = Paster.isTrusted
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Opening the shelf") {
                Toggle("Open when the pointer reaches the notch", isOn: $settings.hoverToOpen)
                Picker("Keyboard shortcut", selection: $settings.hotKey) {
                    ForEach(HotKeyPreset.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let launchError {
                    Text(launchError).font(.caption).foregroundStyle(.red)
                }
            }
            Section("Choosing a clip") {
                Toggle("Click or ↩ pastes into the app you were using", isOn: $settings.pasteOnSelect)
                HStack {
                    Image(systemName: trusted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                    Text(trusted ? "Accessibility permission granted" : "Pasting needs the Accessibility permission")
                    Spacer()
                    if !trusted {
                        Button("Grant…") {
                            Paster.promptForTrust()
                            Paster.openAccessibilitySettings()
                        }
                    }
                }
                .font(.callout)
                Text("Without it, the clip is copied and you press ⌘V yourself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in trusted = Paster.isTrusted }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = "Could not change login item: \(error.localizedDescription). Move NotchClip to Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct CaptureTab: View {
    @ObservedObject var settings: AppSettings
    @State private var newApp = ""

    var body: some View {
        Form {
            Section("Record") {
                Toggle("Images", isOn: $settings.captureImages)
                Toggle("Files copied in Finder", isOn: $settings.captureFiles)
                Toggle("New screenshots saved to disk", isOn: $settings.watchScreenshots)
                Text("Text and links are always recorded. Screenshots copied with ⌃ are recorded as images.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Smart extras") {
                Toggle("Recognise text in images (on-device)", isOn: $settings.recognizeText)
                Toggle("Fetch page titles for links", isOn: $settings.fetchLinkTitles)
                Text("Titles are never fetched for local addresses or links containing tokens or secrets.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Never record from") {
                Text("Password managers (1Password, Bitwarden, Keychain, Passwords, KeePassXC…) and content marked as concealed are always skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(settings.ignoredApps, id: \.self) { id in
                    HStack {
                        Text(appName(id))
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(role: .destructive) {
                            settings.ignoredApps.removeAll { $0 == id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Menu("Add running app…") {
                    ForEach(runningApps, id: \.bundleID) { app in
                        Button(app.name) {
                            if !settings.ignoredApps.contains(app.bundleID) { settings.ignoredApps.append(app.bundleID) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private struct RunningApp: Hashable {
        let name: String
        let bundleID: String
    }

    private var runningApps: [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier else { return nil }
                return RunningApp(name: app.localizedName ?? id, bundleID: id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

private struct HistoryTab: View {
    @ObservedObject var settings: AppSettings
    let commands: SettingsCommands
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("Keep") {
                Picker("Unpinned clips for", selection: $settings.historyDays) {
                    ForEach(AppSettings.historyDayOptions, id: \.self) { Text(AppSettings.historyTitle(days: $0)).tag($0) }
                }
                Picker("At most", selection: $settings.maxItems) {
                    ForEach(AppSettings.maxItemOptions, id: \.self) { Text("\($0) clips").tag($0) }
                }
                Text("Pinned clips are kept forever. Everything is stored only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Data") {
                LabeledContent("Clips stored", value: "\(commands.historyCount())")
                HStack {
                    Button("Show Data Folder") { commands.openDataFolder() }
                    Spacer()
                    Button("Clear Unpinned History…", role: .destructive) { confirmClear = true }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all unpinned clips?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { commands.clearHistory() }
        } message: {
            Text("Pinned clips stay. This cannot be undone.")
        }
    }
}

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("NotchClip").font(.title2.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .foregroundStyle(.secondary)
            Text("Your clipboard history, living in the notch.")
            Link("github.com/Atamutlu33/NotchClip", destination: URL(string: "https://github.com/Atamutlu33/NotchClip")!)
            Text("Inspired by ClipBoardLine by Orkun Işıtmak.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the settings window (activating the app only while it is open).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let makeView: () -> AnyView

    init(makeView: @escaping () -> AnyView) {
        self.makeView = makeView
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "NotchClip Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: makeView())
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        NSApp.deactivate()
    }
}
