import Foundation

/// All methods run on one serial queue. No user-provided paths or commands enter
/// the privileged engine. Dependencies make failures testable without pmset.
struct SessionEnvironment {
    var now: () -> TimeInterval
    var eligible: (Int) -> Bool
    var tooHot: () -> Bool
    var legacyBusy: () -> Bool
    var readSleep: () -> Bool?
    var writeSleep: (Bool) -> Bool
    var loadJournal: () throws -> Bool?
    var saveJournal: (Bool) throws -> Void
    var clearJournal: () throws -> Void
}

final class SessionEngine {
    private let environment: SessionEnvironment
    private var owner: UUID?
    private var started: TimeInterval = 0
    private var heartbeat: TimeInterval = 0
    private var lastSystemCheck: TimeInterval = 0
    private var reserve = 15
    private var previous: Bool?
    private var journalUnreadable = false
    private(set) var state = HelperStatus()
    var needsTick: Bool { owner != nil || (previous != nil && !journalUnreadable) }

    init(environment: SessionEnvironment) {
        self.environment = environment
        do {
            previous = try environment.loadJournal()
            if previous != nil { restore(reason: "Session précédente interrompue.") }
        } catch {
            journalUnreadable = true
            state = .init(restorationFailed: true, message: "Le journal de restauration est illisible. Réinstallation ou intervention nécessaire.")
        }
    }
    func status(for client: UUID) -> HelperStatus {
        guard owner == nil || owner == client else {
            return .init(restorationFailed: true, message: "Une autre instance de Moka utilise déjà le mode capot.")
        }
        return state
    }
    func begin(owner client: UUID, reserve: Int) -> HelperStatus {
        guard (5...50).contains(reserve) else { return .init(message: "Seuil de batterie invalide.") }
        if owner == client { return renew(owner: client, reserve: reserve) }
        guard owner == nil else { return status(for: client) }
        guard !state.restorationFailed, !journalUnreadable else { return state }
        guard !environment.legacyBusy() else {
            return .init(message: "L’ancienne surveillance du capot se termine. Réessayez dans quelques secondes.")
        }
        guard !environment.tooHot(), environment.eligible(reserve) else {
            return .init(message: "Mode capot indisponible : batterie insuffisante, alimentation inconnue ou forte chaleur.")
        }
        guard let old = environment.readSleep() else { return .init(message: "Impossible de lire le réglage de veille macOS.") }
        do { try environment.saveJournal(old) }
        catch { return .init(message: "Impossible de sauvegarder le réglage initial. Le mode reste arrêté.") }
        previous = old
        guard environment.writeSleep(true), environment.readSleep() == true else {
            restore(reason: "macOS n’a pas confirmé l’activation.")
            return state
        }
        owner = client
        self.reserve = reserve
        started = environment.now(); heartbeat = started; lastSystemCheck = started
        state = .init(active: true, previousDisabled: old)
        return state
    }
    func renew(owner client: UUID, reserve: Int) -> HelperStatus {
        guard owner == client else { return status(for: client) }
        guard (5...50).contains(reserve) else {
            restore(reason: "Seuil de batterie invalide."); return state
        }
        // Check expiry before renewing; a delayed message cannot revive a lease.
        tick()
        guard owner == client else { return state }
        self.reserve = reserve
        heartbeat = environment.now()
        tick()
        return state
    }
    func end(owner client: UUID) -> HelperStatus {
        guard owner == client else { return status(for: client) }
        restore(reason: "")
        return state
    }
    func disconnect(owner client: UUID) {
        if owner == client { restore(reason: "Session terminée avec Moka.") }
    }
    func shutdown() {
        if previous != nil { restore(reason: "Service arrêté.") }
    }
    func tick() {
        if state.restorationFailed, previous != nil, !journalUnreadable {
            restore(reason: state.message); return
        }
        guard owner != nil else { return }
        let now = environment.now()
        if now - heartbeat >= HelperConstants.leaseSeconds {
            restore(reason: "Connexion avec Moka interrompue.")
        } else if now - started >= HelperConstants.sessionSeconds {
            restore(reason: "Limite de 4 heures atteinte.")
        } else if environment.tooHot() {
            restore(reason: "Mode capot arrêté : macOS signale une forte chaleur.")
        } else if !environment.eligible(reserve) {
            restore(reason: "Mode capot arrêté : seuil de batterie atteint ou alimentation inconnue.")
        } else if now - lastSystemCheck >= 30 {
            lastSystemCheck = now
            if environment.readSleep() != true { restore(reason: "Le réglage de veille a changé dans macOS.") }
        }
    }
    private func restore(reason: String) {
        owner = nil
        guard let previous else { return }
        // Respect an external re-enabling of sleep; never undo that safer change.
        let current = environment.readSleep()
        let restored = current == false || (environment.writeSleep(previous) && environment.readSleep() == previous)
        guard restored else {
            state = .init(previousDisabled: previous, restorationFailed: true,
                          message: "Restauration de la veille non confirmée. Moka réessaie automatiquement.")
            return
        }
        do { try environment.clearJournal() }
        catch {
            state = .init(previousDisabled: previous, restorationFailed: true,
                          message: "Réglage restauré, mais le journal ne peut pas être effacé.")
            return
        }
        self.previous = nil
        let suffix = previous && current != false ? " La veille était déjà désactivée avant Moka et le reste." : ""
        state = .init(previousDisabled: previous, message: reason + suffix)
    }
}
