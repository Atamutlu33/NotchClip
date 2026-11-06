import AppKit
import NotchClipCore

/// Application entry point.
@MainActor
public enum NotchClipMain {
    private static var delegate: NSApplicationDelegate?

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--self-test") {
            delegate = SelfTestDelegate()
        } else {
            delegate = AppDelegate()
        }
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AppController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            // Already running: one notch is enough.
            NSApp.terminate(nil)
            return
        }
        // `kill`, logout and `pkill` should still restore the user's screenshot settings.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
        let controller = AppController()
        controller.start()
        self.controller = controller
        if controller.settings.isFirstLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated { controller.showWelcome() }
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller?.windowController?.expand(reason: .keyboard)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

@MainActor
final class SelfTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let code = await SelfTest.run()
            exit(code)
        }
    }
}
