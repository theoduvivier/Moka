import AppKit

/// One daily check while idle. Sparkle owns feed verification, UI, downloads,
/// archive validation, installation and relaunch; never the privileged helper.
final class UpdateCoordinator {
    private let defaults: UserDefaults
    private let isBusy: () -> Bool
    private var timer: Timer?
    private var opening = false
    private var started = false
    private static let interval: TimeInterval = 24 * 60 * 60

    init(defaults: UserDefaults = .standard, isBusy: @escaping () -> Bool) {
        self.defaults = defaults
        self.isBusy = isBusy
        defaults.register(defaults: ["mokaAutomaticUpdates": true])
    }
    var automatic: Bool {
        get { defaults.bool(forKey: "mokaAutomaticUpdates") }
        set { defaults.set(newValue, forKey: "mokaAutomaticUpdates"); schedule() }
    }
    func start() { started = true; schedule() }
    func stop() { started = false; timer?.invalidate(); timer = nil }
    func sessionEnded() {
        guard started, automatic, !isBusy(), due else { return }
        launch(manual: false)
    }
    func checkNow() { launch(manual: true) }
    private var due: Bool {
        guard let last = defaults.object(forKey: "mokaLastUpdateAttempt") as? Date else { return true }
        return Date().timeIntervalSince(last) >= Self.interval
    }
    private func schedule() {
        timer?.invalidate(); timer = nil
        guard started, automatic else { return }
        let last = defaults.object(forKey: "mokaLastUpdateAttempt") as? Date ?? .distantPast
        let delay = max(15, last.addingTimeInterval(Self.interval).timeIntervalSinceNow)
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.timer = nil
            // If a session is running, its end calls sessionEnded. No polling.
            guard !self.isBusy() else { return }
            self.launch(manual: false)
        }
        timer?.tolerance = 60
    }
    private func launch(manual: Bool) {
        guard !opening else { return }
        guard manual || (automatic && !isBusy()) else { return }
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/MokaUpdater.app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = manual
        config.arguments = [manual ? "--manual" : "--background"]
        opening = true
        defaults.set(Date(), forKey: "mokaLastUpdateAttempt")
        schedule()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
            DispatchQueue.main.async {
                self?.opening = false
                if manual, let error {
                    NSApp.activate(ignoringOtherApps: true)
                    NSAlert(error: error).runModal()
                }
            }
        }
    }
    deinit { timer?.invalidate() }
}
