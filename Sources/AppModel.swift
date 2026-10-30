import AppKit
import Combine

/// One wake session, one battery cutoff. Old phone/display/duration preferences
/// are deliberately not read, so removed features cannot stay active invisibly.
final class AppModel: ObservableObject {
    private let defaults: UserDefaults
    private let readPower: () -> PowerSnapshot
    private let readThermal: () -> ProcessInfo.ThermalState
    @Published var reserve: Int { didSet {
        defaults.set(reserve, forKey: "reserve")
        lid.setReserve(reserve)
        reconcile()
    } }
    @Published private(set) var enabled = false
    @Published private(set) var awake = false
    @Published private(set) var power: PowerSnapshot
    @Published private(set) var now = Date()
    @Published private(set) var startedAt: Date?
    @Published private(set) var notice: String?
    @Published var error: String?
    @Published var panelVisible = false { didSet {
        configureTimer()
        if panelVisible { tick(refresh: true); lid.refreshSystemState() }
    } }
    let lid: LidGuard
    private let assertions = SleepAssertions()
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var lastRefresh: TimeInterval = -.infinity
    private var activity: NSObjectProtocol?
    private var subscriptions: Set<AnyCancellable> = []

    init(defaults: UserDefaults = .standard, readPower: @escaping () -> PowerSnapshot = PowerSnapshot.read,
         readThermal: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         hasLid: Bool = MacHardware.hasLid) {
        self.defaults = defaults
        self.readPower = readPower
        self.readThermal = readThermal
        self.power = readPower()
        self.reserve = max(5, min(50, ((defaults.object(forKey: "reserve") as? Int ?? 15) + 2) / 5 * 5))
        self.lid = LidGuard(defaults: defaults, isSupported: hasLid)
        lid.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.objectWillChange.send(); self?.configureTimer() }
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.tick(refresh: true) }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification).sink { [weak self] _ in
            self?.reconcile()
        }.store(in: &subscriptions)
        configureTimer()
    }
    var sessionClock: String { SessionPolicy.clock(startedAt: startedAt, now: now) }
    var powerLabel: String {
        let source = power.onBattery ? "Sur batterie" : "Sur secteur"
        return power.percentage.map { "\(source) · \($0) %" } ?? source
    }
    func toggle() { enabled ? stop() : start() }
    func start() {
        guard !enabled else { return }
        error = nil
        notice = nil
        power = readPower()
        guard readThermal().rawValue < ProcessInfo.ThermalState.serious.rawValue else {
            notice = "Le Mac est trop chaud. Laissez-le refroidir avant de démarrer."
            return
        }
        guard !SessionPolicy.reachedReserve(power: power, reserve: reserve) else {
            notice = "Batterie à \(power.percentage ?? reserve) % : rechargez le Mac pour démarrer."
            return
        }
        do { try assertions.activate(display: false) }
        catch { self.error = error.localizedDescription; return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Session Moka en cours")
        now = Date()
        startedAt = now
        enabled = true
        awake = true
        configureTimer()
    }
    func stop() {
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        enabled = false
        awake = false
        startedAt = nil
        assertions.release()
        lid.stop()
        configureTimer()
    }
    private func reconcile() {
        guard enabled else { return }
        if readThermal().rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            stop()
            notice = "Session arrêtée : macOS signale une forte chaleur. Laissez le Mac refroidir sur une surface ventilée."
            return
        }
        if SessionPolicy.reachedReserve(power: power, reserve: reserve) {
            stop()
            notice = "Session arrêtée : batterie à \(power.percentage ?? reserve) %."
        }
    }
    private func configureTimer() {
        let interval = SessionPolicy.timerInterval(enabled: enabled, lidNeedsPulse: lid.needsPulse, panelVisible: panelVisible)
        guard interval != timerInterval else { return }
        timer?.invalidate()
        timerInterval = interval
        guard interval > 0 else { timer = nil; return }
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = interval == 1 ? 0.1 : 1
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func tick(refresh: Bool = false) {
        let timestamp = Date()
        if panelVisible || refresh { now = timestamp }
        if lid.needsPulse { lid.pulse() }
        guard enabled || panelVisible || refresh else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastRefresh >= 5 || refresh {
            lastRefresh = uptime
            let snapshot = readPower()
            if power != snapshot { power = snapshot }
            reconcile()
        }
    }
    func shutdown() { stop(); timer?.invalidate() }
}
