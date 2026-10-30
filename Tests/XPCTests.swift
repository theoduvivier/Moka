import Foundation

final class Endpoint: NSObject, MokaHelperProtocol {
    func beginSession(reserve: Int, reply: @escaping (NSDictionary) -> Void) { reply(HelperStatus(active: (5...50).contains(reserve)).dictionary) }
    func renewSession(reserve: Int, reply: @escaping (NSDictionary) -> Void) { reply(HelperStatus().dictionary) }
    func endSession(reply: @escaping (NSDictionary) -> Void) { reply(HelperStatus().dictionary) }
    func status(reply: @escaping (NSDictionary) -> Void) { reply(HelperStatus().dictionary) }
}
final class Delegate: NSObject, NSXPCListenerDelegate {
    var requirement: String
    init(_ requirement: String) { self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface = NSXPCInterface(with: MokaHelperProtocol.self)
        connection.exportedObject = Endpoint()
        connection.resume(); return true
    }
}
@main enum XPCTests {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[0])
        let requirement = try CodeIdentity.requirement(at: url)
        func exchange(serverRule: String, clientRule: String, expected: Bool, name: String) {
            let listener = NSXPCListener.anonymous(), delegate = Delegate(serverRule)
            listener.setConnectionCodeSigningRequirement(serverRule)
            listener.delegate = delegate; listener.resume()
            let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
            connection.setCodeSigningRequirement(clientRule)
            connection.remoteObjectInterface = NSXPCInterface(with: MokaHelperProtocol.self)
            connection.resume()
            var result: Bool?
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in DispatchQueue.main.async { result = false } } as! MokaHelperProtocol
            proxy.beginSession(reserve: 20) { reply in DispatchQueue.main.async { result = HelperStatus(dictionary: reply)?.active == true } }
            let until = Date().addingTimeInterval(5)
            while result == nil && Date() < until { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
            connection.invalidate(); listener.invalidate()
            withExtendedLifetime(delegate) { precondition(result == expected, name) }
            print("PASS: \(name)")
        }
        exchange(serverRule: requirement, clientRule: requirement, expected: true, name: "Signed XPC peers exchange protocol values")
        let wrong = "identifier \"fr.local.moka.not-the-test-client\""
        exchange(serverRule: wrong, clientRule: requirement, expected: false, name: "Listener rejects a client with the wrong code identity")
        exchange(serverRule: requirement, clientRule: wrong, expected: false, name: "Client rejects a service with the wrong code identity")
        print("3 XPC signature tests passed")
    }
}
