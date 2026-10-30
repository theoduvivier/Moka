import Foundation
import Combine

final class LidGuard: ObservableObject {
    let isSupported: Bool
    @Published private(set) var active = false
    @Published private(set) var pending = false
    @Published private(set) var stopping = false
    @Published private(set) var restorationFailed = false
    @Published private(set) var systemSleepDisabled: Bool?
    @Published private(set) var previousDisabled = false
    @Published private(set) var message: String?
    private let service: LidService
    private let defaults: UserDefaults
    private var generation = UUID()
    private var reserve = 15
    private var inFlight = false
    private var requestingStart = false
    private var lastPulse: TimeInterval = -.infinity
    private var readingSystem = false
    var needsPulse: Bool { active || pending || stopping || restorationFailed }
    var unmanagedSleepDisabled: Bool { !needsPulse && systemSleepDisabled == true }
    var lastDiagnostic: String? { defaults.string(forKey: "lidLastDiagnostic") }

    init(defaults: UserDefaults = .standard, service: LidService = HelperClient(), isSupported: Bool = MacHardware.hasLid) {
        self.isSupported = isSupported
        self.defaults = defaults; self.service = service
    }
    func refreshSystemState() {
        guard !readingSystem else { return }
        readingSystem = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let value = SystemSleep.read()
            DispatchQueue.main.async { [weak self] in
                self?.readingSystem = false
                if self?.systemSleepDisabled != value { self?.systemSleepDisabled = value }
            }
        }
    }
    func start(reserve: Int) {
        guard isSupported else { return }
        guard !needsPulse else { return }
        self.reserve = max(5, min(50, reserve))
        generation = UUID(); let current = generation
        pending = true; message = nil
        service.prepare { [weak self] failure in
            guard let self, self.generation == current, self.pending else { return }
            if let failure { self.pending = false; self.report(failure); return }
            self.requestingStart = true
            self.send(.begin(self.reserve))
        }
    }
    func setReserve(_ value: Int) {
        reserve = max(5, min(50, value))
        lastPulse = -.infinity
        if active { pulse() }
    }
    func stop() {
        guard needsPulse else { return }
        let mayHaveStarted = active || requestingStart || stopping || restorationFailed
        generation = UUID(); inFlight = false
        active = false; pending = false; requestingStart = false
        if mayHaveStarted {
            stopping = true
            send(.end)
        } else { service.invalidate() }
    }
    func pulse() {
        guard !pending, !inFlight, ProcessInfo.processInfo.systemUptime - lastPulse >= 5 else { return }
        if active { send(.renew(reserve)) }
        else if stopping || restorationFailed { send(.status) }
    }
    private func send(_ operation: HelperOperation) {
        guard !inFlight else { return }
        inFlight = true; lastPulse = ProcessInfo.processInfo.systemUptime; let current = generation
        service.request(operation) { [weak self] result in
            guard let self, self.generation == current else { return }
            self.inFlight = false; self.pending = false; self.requestingStart = false
            switch result {
            case .success(let status):
                self.active = status.active
                self.previousDisabled = status.previousDisabled
                self.restorationFailed = status.restorationFailed
                self.stopping = status.restorationFailed
                self.report(status.message.isEmpty ? nil : status.message)
                if !status.active { self.refreshSystemState() }
            case .failure:
                self.active = false; self.stopping = true; self.restorationFailed = true
                self.service.invalidate()
                self.report("Connexion au service interrompue. Le mode capot s’arrête automatiquement ; confirmation de restauration en attente.")
            }
        }
    }
    private func report(_ detail: String?) {
        message = detail
        if let detail {
            defaults.set(detail, forKey: "lidLastDiagnostic")
            defaults.set(Date(), forKey: "lidLastDiagnosticDate")
        }
    }
}
