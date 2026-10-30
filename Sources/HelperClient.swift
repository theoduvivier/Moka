import Foundation

enum HelperOperation { case begin(Int), renew(Int), end, status }
protocol LidService: AnyObject {
    func prepare(completion: @escaping (String?) -> Void)
    func request(_ operation: HelperOperation, completion: @escaping (Result<HelperStatus, Error>) -> Void)
    func invalidate()
}

/// Main-thread client. Every request has a deadline and exactly one completion.
final class HelperClient: LidService {
    private var connection: NSXPCConnection?
    func prepare(completion: @escaping (String?) -> Void) { HelperInstaller.prepare(completion: completion) }
    func request(_ operation: HelperOperation, completion: @escaping (Result<HelperStatus, Error>) -> Void) {
        var completed = false
        func finish(_ result: Result<HelperStatus, Error>) {
            DispatchQueue.main.async {
                guard !completed else { return }
                completed = true; completion(result)
            }
        }
        do {
            if connection == nil {
                let requirement = try CodeIdentity.requirement(at: HelperInstaller.bundledHelper)
                let next = NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged)
                next.setCodeSigningRequirement(requirement)
                next.remoteObjectInterface = NSXPCInterface(with: MokaHelperProtocol.self)
                next.invalidationHandler = { [weak self, weak next] in
                    DispatchQueue.main.async {
                        if self?.connection === next { self?.connection = nil }
                    }
                }
                next.interruptionHandler = { [weak next] in next?.invalidate() }
                connection = next; next.resume()
            }
            guard let connection, let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                finish(.failure(error))
            }) as? MokaHelperProtocol else { throw MokaError(message: "Service Moka indisponible.") }
            let reply: (NSDictionary) -> Void = { data in
                if let state = HelperStatus(dictionary: data) { finish(.success(state)) }
                else { finish(.failure(MokaError(message: "Réponse du service Moka incompatible."))) }
            }
            switch operation {
            case .begin(let reserve): proxy.beginSession(reserve: reserve, reply: reply)
            case .renew(let reserve): proxy.renewSession(reserve: reserve, reply: reply)
            case .end: proxy.endSession(reply: reply)
            case .status: proxy.status(reply: reply)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard !completed else { return }
                connection.invalidate()
                finish(.failure(MokaError(message: "Le service Moka ne répond pas. La session capot sera arrêtée automatiquement.")))
            }
        } catch { finish(.failure(error)) }
    }
    func invalidate() { connection?.invalidate(); connection = nil }
    deinit { connection?.invalidate() }
}
