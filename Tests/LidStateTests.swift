import Foundation

final class FakeService: LidService {
    var authorization: ((String?) -> Void)?
    var requests: [(HelperOperation, (Result<HelperStatus, Error>) -> Void)] = []
    var invalidations = 0
    func prepare(completion: @escaping (String?) -> Void) { authorization = completion }
    func request(_ operation: HelperOperation, completion: @escaping (Result<HelperStatus, Error>) -> Void) { requests.append((operation, completion)) }
    func invalidate() { invalidations += 1 }
}
@main enum LidStateTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ name: String) { precondition(condition, name); count += 1; print("PASS: \(name)") }
        let suite = "fr.local.moka.tests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        do {
            let service = FakeService()
            let lid = LidGuard(defaults: defaults, service: service)
            check(!lid.active && !lid.needsPulse, "Lid mode starts disabled")
            let guardState = LidGuard(defaults: defaults, service: service)
            guardState.start(reserve: 20)
            check(guardState.pending && !guardState.active, "Authorization does not prematurely activate the switch")
            service.authorization?(nil)
            check(service.requests.count == 1 && !guardState.active, "Successful installation still waits for service confirmation")
            service.requests[0].1(.success(.init(active: true)))
            check(guardState.active && !guardState.pending, "Confirmed reply activates the switch")
            guardState.stop()
            check(!guardState.active && guardState.stopping, "Stop retains restoration indicator")
            service.requests[1].1(.success(.init()))
            check(!guardState.stopping && !guardState.needsPulse, "Confirmed restoration clears indicator")
        }
        do {
            let service = FakeService()
            let lid = LidGuard(defaults: defaults, service: service)
            lid.start(reserve: 20); lid.stop(); service.authorization?(nil)
            check(service.requests.isEmpty && !lid.active, "Late authorization after Stop cannot start a session")
        }
        do {
            let service = FakeService()
            let state = LidGuard(defaults: defaults, service: service)
            state.start(reserve: 20); service.authorization?("Annulée")
            check(!state.needsPulse && state.message == "Annulée", "Cancelled installation leaves no uncertain protection")
        }
        do {
            let service = FakeService(); let lid = LidGuard(defaults: defaults, service: service)
            lid.start(reserve: 20); service.authorization?(nil); lid.stop()
            service.requests[0].1(.success(.init(active: true)))
            check(!lid.active && lid.stopping, "Stale Begin reply cannot reverse Stop")
            service.requests[1].1(.success(.init()))
            check(!lid.needsPulse, "End reply completes a cancelled pending start")
        }
        do {
            let service = FakeService(); let lid = LidGuard(defaults: defaults, service: service)
            lid.start(reserve: 20); service.authorization?(nil)
            service.requests[0].1(.failure(NSError(domain: "test", code: 1)))
            check(lid.restorationFailed && lid.stopping && !lid.active && service.invalidations == 1, "Lost service invalidates lease and keeps warning visible")
        }
        print("\(count) lid client tests passed")
    }
}
