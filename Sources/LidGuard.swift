import Foundation
import Combine
import Darwin
import OSLog

/// Fixed privileged code, never loaded from a user-writable executable or script.
/// Only the heartbeat is read there; all privileged writes stay in /var/run.
enum LidGuardScript {
    static let stateDirectory = "/private/var/run/fr.local.moka-lid"
    static let resultPath = stateDirectory + ".result"
    /// Keep the authorized parent alive until the child confirms startup. A
    /// successful asynchronous spawn alone says nothing about the child result.
    static func launch(script: String, token: String) -> String {
        let state = ShellEscaping.quote(stateDirectory)
        let result = ShellEscaping.quote(resultPath)
        return """
        [ "$(/usr/bin/id -u)" = 0 ] || { /usr/bin/printf '%s\\n' 'MOKA_NOT_ROOT' >&2; exit 77; }
        log=$(/usr/bin/mktemp /private/var/run/fr.local.moka-launch.XXXXXX) || { /usr/bin/printf '%s\\n' 'MOKA_LOG_FAILED' >&2; exit 77; }
        trap '/bin/rm -f "$log"' EXIT
        # macOS nohup also detaches from the console via launch services, which
        # can fail in an authorized AppleScript context. Ignore HUP without it.
        (trap '' HUP; exec /bin/sh -p -c \(ShellEscaping.quote(script))) </dev/null >"$log" 2>&1 &
        worker=$!
        attempt=0
        while [ "$attempt" -lt 80 ]; do
          observed=$(/bin/cat \(state)/token 2>/dev/null)
          [ "$observed" = \(ShellEscaping.quote(token)) ] && /bin/kill -0 "$worker" 2>/dev/null && exit 0
          completed=$(/usr/bin/sed -n '1p' \(result) 2>/dev/null)
          [ "$completed" = \(ShellEscaping.quote(token)) ] && exit 0
          if ! /bin/kill -0 "$worker" 2>/dev/null; then
            /usr/bin/printf '%s\\n' 'MOKA_WORKER_EXIT' >&2
            /usr/bin/tail -c 1200 "$log" >&2
            exit 77
          fi
          attempt=$((attempt + 1))
          /bin/sleep 0.1
        done
        /usr/bin/printf '%s\\n' 'MOKA_START_TIMEOUT' >&2
        /usr/bin/tail -c 1200 "$log" >&2
        exit 78
        """
    }
    static func make(heartbeat: String, token: String, parentPID: Int32, reserve: Int) -> String {
        let beat = ShellEscaping.quote(heartbeat)
        let state = ShellEscaping.quote(stateDirectory)
        let result = ShellEscaping.quote(resultPath)
        return """
        umask 022
        old=unknown
        report() {
          /usr/bin/printf '%s\\n' \(ShellEscaping.quote(token)) "$1" "$old" "$2" > \(result).tmp && /bin/mv -f \(result).tmp \(result)
        }
        if ! /bin/mkdir \(state) 2>/dev/null; then
          # Recover only our recorded, dead guard. Never kill another process.
          pid=$(/bin/cat \(state)/pid 2>/dev/null)
          previous=$(/bin/cat \(state)/previous 2>/dev/null)
          case "$pid" in ''|*[!0-9]*) report busy 0; exit 73 ;; esac
          [ "$pid" -gt 1 ] || { report busy 0; exit 73; }
          /bin/kill -0 "$pid" 2>/dev/null && { report busy 0; exit 73; }
          case "$previous" in 0|1) ;; *) report busy 0; exit 73 ;; esac
          old=$previous
          /usr/bin/pmset -a disablesleep "$old" || { report restore_failed 0; exit 75; }
          /bin/rm -f \(state)/token \(state)/pid \(state)/previous
          /bin/rmdir \(state) && /bin/mkdir \(state) || { report busy 0; exit 73; }
        fi
        old=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2; exit}')
        case "$old" in 0|1) ;; *) report read_failed 0; /bin/rmdir \(state); exit 74 ;; esac
        changed=0
        reason=stopped
        /usr/bin/printf '%s' "$$" > \(state)/pid
        /usr/bin/printf '%s' "$old" > \(state)/previous
        cleanup() {
          if [ "$changed" = 1 ]; then
            /usr/bin/pmset -a disablesleep "$old" || { report restore_failed 0; exit 75; }
            restored=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2; exit}')
            [ "$restored" = "$old" ] || { report restore_failed 0; exit 75; }
          fi
          report "$reason" 1
          /bin/rm -f \(state)/token \(state)/pid \(state)/previous
          /bin/rmdir \(state)
        }
        trap cleanup EXIT
        trap 'reason=signal; exit 0' HUP INT TERM
        eligible() {
          [ -f \(beat) ] || { reason=stopped; return 1; }
          /bin/kill -0 \(parentPID) 2>/dev/null || { reason=app_exited; return 1; }
          now=$(/bin/date +%s)
          stamp=$(/usr/bin/stat -f %m \(beat) 2>/dev/null) || { if [ -f \(beat) ]; then reason=heartbeat; else reason=stopped; fi; return 1; }
          [ $((now - stamp)) -ge 0 ] && [ $((now - stamp)) -le 20 ] || { reason=heartbeat; return 1; }
          battery=$(/usr/bin/pmset -g batt)
          case "$battery" in
            *"Battery Power"*)
              level=$(/usr/bin/printf '%s' "$battery" | /usr/bin/awk 'match($0, /[0-9]+%/) {print substr($0, RSTART, RLENGTH-1); exit}')
              case "$level" in ''|*[!0-9]*) reason=battery_unknown; return 1 ;; esac
              cutoff=$(/usr/bin/head -c 3 \(beat) 2>/dev/null) || { if [ -f \(beat) ]; then reason=heartbeat; else reason=stopped; fi; return 1; }
              # Only a bounded decimal value is accepted. Never evaluate input.
              case "$cutoff" in [5-9]|[1-4][0-9]|50) ;; *) cutoff=\(max(5, min(50, reserve))) ;; esac
              [ "$level" -gt "$cutoff" ] || { reason=battery; return 1; }
              ;;
            *"AC Power"*) ;;
            *) reason=battery_unknown; return 1 ;;
          esac
        }
        eligible || exit 0
        changed=1
        /usr/bin/pmset -a disablesleep 1 || { reason=activate_failed; exit 76; }
        actual=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2; exit}')
        [ "$actual" = 1 ] || { reason=activate_failed; exit 76; }
        /usr/bin/printf '%s' \(ShellEscaping.quote(token)) > \(state)/token
        start=$(/bin/date +%s)
        while eligible; do
          [ $((now - start)) -lt 14400 ] || { reason=limit; break; }
          actual=$(/usr/bin/pmset -g | /usr/bin/awk '/SleepDisabled/ {print $2; exit}')
          if [ "$actual" != 1 ]; then
            # Respect an external change instead of overwriting it on cleanup.
            if [ "$actual" = 0 ]; then changed=0; fi
            reason=system_changed
            break
          fi
          /bin/sleep 2
        done
        """
    }
}

struct LidGuardRecord {
    var token: String
    var pid: Int32
    var previousDisabled: Bool
    static func read() -> LidGuardRecord? {
        func field(_ name: String) -> String? { try? String(contentsOfFile: LidGuardScript.stateDirectory + "/" + name, encoding: .utf8) }
        guard let token = field("token"), let rawPID = field("pid"), let pid = Int32(rawPID), pid > 1,
              let previous = field("previous"), ["0", "1"].contains(previous) else { return nil }
        return .init(token: token, pid: pid, previousDisabled: previous == "1")
    }
}
struct LidGuardResult {
    var token: String
    var reason: String
    var previous: String
    var restored: Bool
    init?(text: String) {
        let fields = text.split(separator: "\n").map(String.init)
        guard fields.count == 4, ["0", "1"].contains(fields[3]) else { return nil }
        token = fields[0]; reason = fields[1]; previous = fields[2]; restored = fields[3] == "1"
    }
    var message: String {
        let detail: String
        switch reason {
        case "busy": return "Une autre surveillance du capot est encore présente. Réessayez après sa fermeture."
        case "read_failed": return "Impossible de lire le réglage de veille macOS. Le mode capot fermé n’est pas activé."
        case "activate_failed": detail = "macOS n’a pas confirmé l’activation du mode capot fermé."
        case "restore_failed": return "La restauration de la veille a échoué. Vérifiez avec pmset -g ; pour autoriser la veille : sudo pmset -a disablesleep 0."
        case "heartbeat": detail = "Le mode capot fermé s’est arrêté : la surveillance de Moka a été interrompue."
        case "battery": detail = "Le mode capot fermé s’est arrêté au seuil de réserve de batterie."
        case "battery_unknown": detail = "Le mode capot fermé s’est arrêté : le niveau de batterie n’est pas disponible."
        case "limit": detail = "Le mode capot fermé a atteint sa limite de 4 heures."
        case "system_changed": return "Le réglage de veille a changé dans macOS. Moka a arrêté sa surveillance du capot."
        case "app_exited": detail = "Le mode capot fermé s’est arrêté avec l’application."
        case "signal": detail = "Le surveillant du capot fermé a été arrêté."
        default: detail = "Le mode capot fermé est arrêté."
        }
        guard restored else { return detail + " Restauration de la veille non confirmée." }
        return detail + (previous == "1" ? " La veille était déjà désactivée avant cette session et le reste." : " Le réglage initial a été rétabli.")
    }
}

enum LidLaunchFailure {
    static func message(detail: String) -> String {
        if detail.contains("-128") { return "Activation annulée." }
        if detail.contains("MOKA_NOT_ROOT") { return "macOS n’a pas transmis les droits administrateur au surveillant. Le mode reste désactivé." }
        if detail.contains("MOKA_LOG_FAILED") { return "Le surveillant ne peut pas créer son fichier de démarrage dans macOS. Le mode reste désactivé." }
        if detail.contains("MOKA_START_TIMEOUT") { return "Le surveillant ne répond pas après son lancement. Le mode reste désactivé." }
        let lines = detail.components(separatedBy: .newlines).filter { !$0.isEmpty && !$0.contains("MOKA_WORKER_EXIT") }
        let diagnostic = String((lines.first ?? detail).prefix(320))
        if detail.contains("MOKA_WORKER_EXIT") { return "Le surveillant s’est arrêté au démarrage. \(diagnostic)" }
        return "Échec du lancement administrateur. \(diagnostic)"
    }
}

struct LidGuardDependencies {
    var now: () -> Date = Date.init
    var record: () -> LidGuardRecord? = LidGuardRecord.read
    var result: () -> LidGuardResult? = {
        (try? String(contentsOfFile: LidGuardScript.resultPath, encoding: .utf8)).flatMap(LidGuardResult.init)
    }
    var alive: (Int32) -> Bool = { kill($0, 0) == 0 || errno == EPERM }
    var authorize: (String, @escaping (String?) -> Void) -> Void = { script, completion in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let errors = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            let failure: String?
            do {
                try process.run()
                // Drain the pipe before waiting, so a full pipe cannot deadlock.
                let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                failure = process.terminationStatus == 0 ? nil : LidLaunchFailure.message(detail: detail)
            } catch { failure = error.localizedDescription }
            DispatchQueue.main.async { completion(failure) }
        }
    }
    var readSystem: (@escaping (Bool?) -> Void) -> Void = { completion in
        DispatchQueue.global(qos: .utility).async {
            let process = Process(); let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["-g"]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            var disabled: Bool?
            if (try? process.run()) != nil {
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                process.waitUntilExit()
                if process.terminationStatus == 0 {
                    let words = output.split(whereSeparator: { $0.isWhitespace })
                    if let index = words.firstIndex(of: "SleepDisabled"), words.indices.contains(index + 1), ["0", "1"].contains(words[index + 1]) { disabled = words[index + 1] == "1" }
                }
            }
            let value = disabled
            DispatchQueue.main.async { completion(value) }
        }
    }
}

final class LidGuard: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var pending = false
    @Published private(set) var stopping = false
    @Published private(set) var restorationFailed = false
    @Published private(set) var systemSleepDisabled: Bool?
    @Published private(set) var previousDisabled = false
    @Published var message: String? {
        didSet {
            if let message {
                defaults.set(message, forKey: "lidLastDiagnostic")
                defaults.set(dependencies.now(), forKey: "lidLastDiagnosticDate")
                Self.logger.notice("\(message, privacy: .public)")
            }
        }
    }
    private static let logger = Logger(subsystem: "fr.local.moka", category: "lid")
    private let defaults: UserDefaults
    private let dependencies: LidGuardDependencies
    private var directory: URL?
    private var token: String?
    private var authorizedAt: Date?
    private var stoppedAt: Date?
    private var generation = UUID()
    private var readingSystem = false
    var needsPulse: Bool { pending || active || stopping }
    var unmanagedSleepDisabled: Bool { !needsPulse && systemSleepDisabled == true }
    var lastDiagnostic: String? { defaults.string(forKey: "lidLastDiagnostic") }

    init(defaults: UserDefaults = .standard, dependencies: LidGuardDependencies = .init()) {
        self.defaults = defaults; self.dependencies = dependencies
    }
    func refreshSystemState() {
        guard !readingSystem else { return }
        readingSystem = true
        dependencies.readSystem { [weak self] value in
            guard let self else { return }
            self.readingSystem = false
            if self.systemSleepDisabled != value { self.systemSleepDisabled = value }
        }
    }
    func start(reserve: Int) {
        guard !needsPulse else { return }
        let generation = UUID(); self.generation = generation
        message = nil; pending = true; authorizedAt = nil
        let token = UUID().uuidString; self.token = token
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moka-lid-\(token)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            self.directory = directory
            try Data("\(max(5, min(50, reserve)))\n".utf8).write(to: directory.appendingPathComponent("heartbeat"), options: .atomic)
        } catch { fail(error.localizedDescription); return }
        let script = LidGuardScript.make(heartbeat: directory.appendingPathComponent("heartbeat").path, token: token, parentPID: ProcessInfo.processInfo.processIdentifier, reserve: reserve)
        let command = "/bin/sh -p -c \(ShellEscaping.quote(LidGuardScript.launch(script: script, token: token)))"
        let appleScript = "do shell script \(ShellEscaping.appleScriptString(command)) with administrator privileges with prompt \(ShellEscaping.appleScriptString("Autorisez Moka à maintenir votre Mac éveillé capot fermé pendant cette session."))"
        dependencies.authorize(appleScript) { [weak self] failure in
            guard let self, self.generation == generation else { return }
            if let failure { self.fail(failure); return }
            self.authorizedAt = self.dependencies.now()
            self.pulse()
        }
    }
    private func fail(_ detail: String) {
        pending = false; active = false
        message = detail
        removeHeartbeat()
        refreshSystemState()
    }
    func setReserve(_ reserve: Int) {
        guard pending || active, let directory else { return }
        do {
            try Data("\(max(5, min(50, reserve)))\n".utf8)
                .write(to: directory.appendingPathComponent("heartbeat"), options: .atomic)
        } catch {
            stop()
            message = "Le mode capot s’est arrêté : le seuil de batterie n’a pas pu être actualisé."
        }
    }
    func pulse() {
        if pending || active, let directory {
            do { try FileManager.default.setAttributes([.modificationDate: dependencies.now()], ofItemAtPath: directory.appendingPathComponent("heartbeat").path) }
            catch { stop(); message = "Le mode capot fermé s’est arrêté : Moka ne peut plus actualiser sa surveillance." }
        }
        guard let token else { return }
        let record = dependencies.record()
        let own = record?.token == token
        let result = dependencies.result().flatMap { $0.token == token ? $0 : nil }
        if pending, authorizedAt != nil {
            if let record, own, dependencies.alive(record.pid), result == nil {
                previousDisabled = record.previousDisabled
                restorationFailed = false
                pending = false; active = true; systemSleepDisabled = true
                Self.logger.notice("Surveillance du capot confirmée.")
            } else if let result {
                if result.reason == "restore_failed" { restorationFailed = true }
                fail(result.message)
            }
            else if dependencies.now().timeIntervalSince(authorizedAt!) > 8 { fail("L’autorisation a été acceptée, mais le surveillant du capot n’a pas confirmé son démarrage. Le mode reste désactivé.") }
        }
        if active, !own || record.map({ !dependencies.alive($0.pid) }) == true || result != nil {
            active = false
            restorationFailed = result == nil || result?.restored == false
            removeHeartbeat()
            message = result?.message ?? "La surveillance du capot fermé a été interrompue. Le réglage de veille doit être vérifié."
            refreshSystemState()
        }
        if stopping {
            if let result, !result.restored {
                stopping = false
                restorationFailed = true
                if message != result.message { message = result.message }
                refreshSystemState()
            } else if !own {
                stopping = false
                if let result { message = result.message }
                refreshSystemState()
            } else if record.map({ !dependencies.alive($0.pid) }) == true {
                stopping = false
                restorationFailed = true
                message = "Le surveillant s’est interrompu avant de confirmer la restauration. Vérifiez la veille avec pmset -g."
                refreshSystemState()
            } else if stoppedAt.map({ dependencies.now().timeIntervalSince($0) > 12 }) == true {
                let warning = "Restauration non confirmée. Vérifiez avec pmset -g ; pour autoriser la veille : sudo pmset -a disablesleep 0."
                if message != warning { message = warning }
            }
        }
    }
    func stop() {
        let wasRunning = active || (pending && dependencies.record()?.token == token)
        generation = UUID()
        active = false; pending = false; authorizedAt = nil
        removeHeartbeat()
        if wasRunning { stopping = true; stoppedAt = dependencies.now() }
    }
    private func removeHeartbeat() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
    deinit { removeHeartbeat() }
}
