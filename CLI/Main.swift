import Foundation
import Darwin
import MachO

/// The caller execs the requested command: stdin, job control, signals and the
/// exit code remain those of the command. A small child watches that PID and
/// owns the assertion. No shell interpolation and no administrative service.
@main enum MokaCLI {
    static func log(_ text: String) { FileHandle.standardError.write(Data(("Moka : " + text + "\n").utf8)) }
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--watch", args.count == 3, let parent = Int32(args[1]),
           parent == getppid(), parent > 1, let reserve = Int(args[2]), (5...50).contains(reserve) {
            watch(parent: parent, reserve: reserve)
        }
        if args.isEmpty || args == ["--help"] || args == ["help"] {
            print("""
            Usage : moka run [--reserve 5…50] [--] commande [arguments…]
            Exemple : moka run npm run build

            Le Mac reste éveillé pendant la commande ; l’écran peut s’éteindre.
            Le capot fermé n’est pas activé. Au seuil de batterie ou en cas de
            forte chaleur, la protection s’arrête ; la commande n’est pas tuée.
            Le code de sortie et les entrées/sorties de la commande sont conservés.
            """)
            return
        }
        guard args.first == "run" else { log("commande inconnue. Utilisez moka --help."); exit(64) }
        var command = Array(args.dropFirst())
        let saved = CFPreferencesCopyAppValue("reserve" as CFString, "fr.local.moka" as CFString) as? Int ?? 15
        var reserve = min(50, max(5, saved))
        if command.first == "--reserve" {
            guard command.count >= 3, let value = Int(command[1]), (5...50).contains(value) else {
                log("le seuil doit être compris entre 5 et 50 %."); exit(64)
            }
            reserve = value; command.removeFirst(2)
        }
        if command.first == "--" { command.removeFirst() }
        guard let executable = command.first, !executable.isEmpty else { log("indiquez une commande à exécuter."); exit(64) }
        do { try startWatcher(reserve: reserve) }
        catch { log(error.localizedDescription); exit(69) }
        var argv = command.map { strdup($0) } + [nil]
        argv.withUnsafeMutableBufferPointer { buffer in _ = execvp(executable, buffer.baseAddress!) }
        let failure = errno
        log("impossible de lancer \(executable) : \(String(cString: strerror(failure))).")
        argv.forEach { free($0) }
        exit(failure == ENOENT ? 127 : 126)
    }
    private static func startWatcher(reserve: Int) throws {
        var size: UInt32 = 0
        _NSGetExecutablePath(nil, &size)
        var path = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&path, &size) == 0 else { throw MokaError(message: "exécutable introuvable.") }
        let executable = String(cString: path)
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw MokaError(message: "impossible de préparer la surveillance.") }
        defer { close(descriptors[0]); close(descriptors[1]) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_addclose(&actions, descriptors[0])
        posix_spawn_file_actions_addclose(&actions, descriptors[1])
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var argv = [executable, "--watch", String(getpid()), String(reserve)].map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        let result = argv.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(&child, executable, &actions, &attributes, buffer.baseAddress!, environ)
        }
        guard result == 0 else { throw MokaError(message: String(cString: strerror(result))) }
        // Stop holding a writer locally, so startup failures produce EOF.
        close(descriptors[1]); descriptors[1] = -1
        var descriptor = pollfd(fd: descriptors[0], events: Int16(POLLIN), revents: 0)
        var ready = [UInt8](repeating: 0, count: 6)
        if poll(&descriptor, 1, 10_000) > 0, read(descriptors[0], &ready, 6) == 6,
           String(bytes: ready, encoding: .utf8) == "READY\n" { return }
        kill(child, SIGTERM)
        var status: Int32 = 0
        while waitpid(child, &status, 0) < 0 && errno == EINTR {}
        throw MokaError(message: "la protection n’a pas démarré. La commande n’a pas été exécutée.")
    }
    private static func watch(parent: pid_t, reserve: Int) -> Never {
        let assertions = SleepAssertions()
        let lock: SessionLock
        do {
            lock = try SessionLock(exclusive: false)
            guard !SessionPolicy.reachedReserve(power: PowerSnapshot.read(), reserve: reserve) else {
                throw MokaError(message: "batterie au seuil de \(reserve) % ; rechargez avant de lancer la commande.")
            }
            guard ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else {
                throw MokaError(message: "le Mac est trop chaud ; laissez-le refroidir.")
            }
            try assertions.activate(display: false, reason: "Moka — commande Terminal")
        } catch { log(error.localizedDescription); exit(69) }
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Commande Moka en cours")
        var protected = true
        let timer = DispatchSource.makeTimerSource(queue: .main)
        let ended = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
        func release() {
            guard protected else { return }
            protected = false; assertions.release()
            ProcessInfo.processInfo.endActivity(activity)
            timer.cancel()
        }
        ended.setEventHandler { release(); log("commande terminée ; protection libérée."); exit(0) }
        ended.resume()
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler {
            if SessionPolicy.reachedReserve(power: PowerSnapshot.read(), reserve: reserve)
                || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                release()
                log("protection arrêtée (batterie ou chaleur). La commande continue sans maintien éveillé.")
            }
        }
        timer.resume()
        guard getppid() == parent, kill(parent, 0) == 0 else { release(); exit(0) }
        log("Mac éveillé pendant la commande ; écran libre de s’éteindre. Arrêt de la protection à \(reserve) %.")
        FileHandle.standardOutput.write(Data("READY\n".utf8))
        try? FileHandle.standardOutput.close()
        withExtendedLifetime((lock, ended, timer, assertions)) { dispatchMain() }
    }
}
