import AppKit
import Sparkle

/// Sparkle runs in a separate, unprivileged process. Moka and its root helper
/// retain Hardened Runtime + Library Validation even in ad-hoc builds.
final class UpdateDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    private var updater: SPUUpdater?
    private let background = CommandLine.arguments.contains("--background")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard let host = Bundle(url: hostURL), host.bundleIdentifier == "fr.local.moka" else {
            NSApp.terminate(nil); return
        }
        let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: self)
        self.updater = updater
        do {
            try updater.start()
            if background { updater.checkForUpdatesInBackground() }
            else { NSApp.activate(ignoringOtherApps: true); updater.checkForUpdates() }
        } catch {
            if !background {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        updater?.checkForUpdates()
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // No scheduler or background process remains after the check/dialog.
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

@main enum MokaUpdaterMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = UpdateDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
