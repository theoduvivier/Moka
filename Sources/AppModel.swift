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
    @Published private(set) var stopReason: SessionStopReason?
    @Published private(set) var summary: SessionSummary?
    @Published private(set) var batteryPoints: Int?
    @Published var uninstalling = false
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
    private var battery: SessionBattery?
    private var startedUptime: TimeInterval?
    private let uptime: () -> TimeInterval

    init(defaults: UserDefaults = .standard, readPower: @escaping () -> PowerSnapshot = PowerSnapshot.read,
         readThermal: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         hasLid: Bool = MacHardware.hasLid,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.readPower = readPower
        self.readThermal = readThermal
        self.uptime = uptime
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
    var headline: String {
        if uninstalling { return "Désinstallation…" }
        if awake { return "Votre Mac reste éveillé" }
        switch stopReason {
        case .battery: return "Batterie faible"
        case .thermal: return "Mac trop chaud"
        case .manual: return "Session terminée"
        case nil: return "Moka est au repos"
        }
    }
    var explanation: String {
        if uninstalling { return "Arrêt de la session et retrait de Moka." }
        if awake {
            return lid.active ? "Vos tâches continuent, même écran éteint et capot fermé."
                : "L’écran peut s’éteindre. Votre Mac continue de travailler."
        }
        if lid.needsPulse { return "Restauration de la veille en cours. Gardez Moka ouvert." }
        if lid.unmanagedSleepDisabled { return "Un autre réglage système bloque encore la veille." }
        switch stopReason {
        case .battery(let level): return "Arrêt automatique à \(level) %. Rechargez pour reprendre."
        case .thermal: return "Session arrêtée. Laissez le Mac refroidir avant de reprendre."
        case .manual, nil: return "Moka laisse votre Mac suivre ses réglages de veille."
        }
    }
    var sessionDetail: String? {
        if enabled { return batteryPoints.map { "Batterie du Mac depuis le départ : \($0 == 0 ? "0" : "−\($0)") pt\($0 == 1 ? "" : "s")" } }
        return summary?.text
    }
    func toggle() { enabled ? stop() : start() }
    func start() {
        guard !enabled, !uninstalling, !lid.stopping, !lid.restorationFailed else { return }
        error = nil
        notice = nil
        power = readPower()
        guard readThermal().rawValue < ProcessInfo.ThermalState.serious.rawValue else {
            stopReason = .thermal
            notice = "Le Mac est trop chaud. Laissez-le refroidir avant de démarrer."
            return
        }
        guard !SessionPolicy.reachedReserve(power: power, reserve: reserve) else {
            stopReason = .battery(power.percentage ?? reserve)
            notice = "Batterie à \(power.percentage ?? reserve) % : rechargez le Mac pour démarrer."
            return
        }
        do { try assertions.activate(display: false) }
        catch { self.error = error.localizedDescription; return }
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Session Moka en cours")
        now = Date()
        startedAt = now
        startedUptime = uptime()
        battery = SessionBattery(power)
        batteryPoints = battery?.points
        summary = nil; stopReason = nil
        enabled = true
        awake = true
        configureTimer()
    }
    func stop(reason: SessionStopReason = .manual) {
        if enabled {
            let snapshot = readPower()
            power = snapshot
            battery?.observe(snapshot)
            batteryPoints = battery?.points
            summary = SessionSummary(seconds: max(0, uptime() - (startedUptime ?? uptime())), batteryPoints: batteryPoints)
            stopReason = reason
        }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        enabled = false
        awake = false
        startedAt = nil
        startedUptime = nil
        assertions.release()
        lid.stop()
        configureTimer()
    }
    private func reconcile() {
        guard enabled else { return }
        if readThermal().rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            stop(reason: .thermal)
            notice = "Session arrêtée : macOS signale une forte chaleur. Laissez le Mac refroidir sur une surface ventilée."
            return
        }
        if SessionPolicy.reachedReserve(power: power, reserve: reserve) {
            let level = power.percentage ?? reserve
            stop(reason: .battery(level))
            notice = "Session arrêtée : batterie à \(level) %."
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
            if enabled {
                battery?.observe(snapshot)
                if batteryPoints != battery?.points { batteryPoints = battery?.points }
            }
            if power != snapshot { power = snapshot }
            reconcile()
        }
    }
    func shutdown() { stop(); timer?.invalidate() }
}
