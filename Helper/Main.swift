import Foundation
import IOKit.ps
import Darwin

enum ProtectedFiles {
    static func isProtected(_ path: String, directory: Bool = false) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_uid == 0 && info.st_mode & 0o022 == 0 &&
            (info.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG)
    }
    static func configuration() -> (uid_t, String)? {
        guard ["/Library", "/Library/Application Support", HelperConstants.directory].allSatisfy({ isProtected($0, directory: true) }),
              isProtected(HelperConstants.configuration),
              let data = FileManager.default.contents(atPath: HelperConstants.configuration),
              let config = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let uid = config["uid"] as? UInt32, uid > 0,
              let requirement = config["clientRequirement"] as? String, !requirement.isEmpty, requirement.count < 16_384 else { return nil }
        return (uid, requirement)
    }
    static func environment() -> SessionEnvironment {
        .init(now: { ProcessInfo.processInfo.systemUptime }, eligible: { reserve in
            guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
                  let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return false }
            if provider == kIOPSACPowerValue { return true }
            guard provider == kIOPSBatteryPowerValue,
                  let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = d[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = d[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                return current * 100 / maximum > reserve
            }
            return false
        }, tooHot: { ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue },
        legacyBusy: { FileManager.default.fileExists(atPath: "/private/var/run/fr.local.moka-lid") },
        readSleep: SystemSleep.read, writeSleep: SystemSleep.write,
        loadJournal: {
            guard FileManager.default.fileExists(atPath: HelperConstants.journal) else { return nil }
            guard isProtected(HelperConstants.journal),
                  let data = FileManager.default.contents(atPath: HelperConstants.journal),
                  let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let previous = record["previous"] as? Bool else {
                throw NSError(domain: "MokaJournal", code: 1)
            }
            return previous
        }, saveJournal: { previous in
            let data = try PropertyListSerialization.data(fromPropertyList: ["previous": previous], format: .binary, options: 0)
            try data.write(to: URL(fileURLWithPath: HelperConstants.journal), options: .atomic)
            guard chmod(HelperConstants.journal, 0o600) == 0 else { throw NSError(domain: "MokaJournal", code: 2) }
            let descriptor = open(HelperConstants.journal, O_RDONLY | O_NOFOLLOW)
            guard descriptor >= 0 else { throw NSError(domain: "MokaJournal", code: 3) }
            defer { close(descriptor) }
            guard fsync(descriptor) == 0 else { throw NSError(domain: "MokaJournal", code: 4) }
        }, clearJournal: { try FileManager.default.removeItem(atPath: HelperConstants.journal) })
    }
}

final class HelperServer: NSObject, NSXPCListenerDelegate {
    let queue = DispatchQueue(label: "fr.local.moka.helper.state", qos: .utility)
    let engine = SessionEngine(environment: ProtectedFiles.environment())
    let uid: uid_t
    let requirement: String
    private var timer: DispatchSourceTimer?
    init(uid: uid_t, requirement: String) { self.uid = uid; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == uid else { return false }
        // Audit-token-bound validation, never a racy PID lookup.
        connection.setCodeSigningRequirement(requirement)
        let owner = UUID()
        connection.exportedInterface = NSXPCInterface(with: MokaHelperProtocol.self)
        connection.exportedObject = HelperEndpoint(server: self, owner: owner)
        connection.invalidationHandler = { [weak self] in
            guard let self else { return }
            self.queue.async { self.engine.disconnect(owner: owner); self.updateTimer() }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        return true
    }
    func updateTimer() {
        if !engine.needsTick { timer?.cancel(); timer = nil; return }
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.engine.tick(); self?.updateTimer() }
        self.timer = timer; timer.resume()
    }
}

final class HelperEndpoint: NSObject, MokaHelperProtocol {
    let server: HelperServer
    let owner: UUID
    init(server: HelperServer, owner: UUID) { self.server = server; self.owner = owner }
    private func perform(_ reply: @escaping (NSDictionary) -> Void, _ action: @escaping (SessionEngine, UUID) -> HelperStatus) {
        server.queue.async { [self] in
            let status = action(server.engine, owner)
            server.updateTimer(); reply(status.dictionary)
        }
    }
    func beginSession(reserve: Int, reply: @escaping (NSDictionary) -> Void) {
        perform(reply) { $0.begin(owner: $1, reserve: reserve) }
    }
    func renewSession(reserve: Int, reply: @escaping (NSDictionary) -> Void) {
        perform(reply) { $0.renew(owner: $1, reserve: reserve) }
    }
    func endSession(reply: @escaping (NSDictionary) -> Void) { perform(reply) { $0.end(owner: $1) } }
    func status(reply: @escaping (NSDictionary) -> Void) { perform(reply) { $0.status(for: $1) } }
}

@main enum HelperMain {
    static func main() {
        guard geteuid() == 0, let (uid, requirement) = ProtectedFiles.configuration() else { exit(77) }
        umask(0o077)
        let server = HelperServer(uid: uid, requirement: requirement)
        let listener = NSXPCListener(machServiceName: HelperConstants.label)
        listener.setConnectionCodeSigningRequirement(requirement)
        listener.delegate = server
        signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
        let signals = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: server.queue)
            source.setEventHandler { server.engine.shutdown(); exit(0) }
            source.resume(); return source
        }
        server.queue.async { server.updateTimer() }
        listener.resume()
        withExtendedLifetime((server, listener, signals)) { RunLoop.main.run() }
    }
}
