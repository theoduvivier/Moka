import Foundation
import Darwin

/// Exercises the real launcher + AppleScript quoting with fake power commands.
/// No administrator authorization, real power settings, or /var/run writes.
@main enum LidLaunchTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moka-launch-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let beat = root.appendingPathComponent("heartbeat")
        let fake = root.appendingPathComponent("pmset")
        let tempLog = root.appendingPathComponent("launch.XXXXXX")
        let token = "launch-test-token"
        var count = 0
        func check(_ value: Bool, _ title: String) {
            guard value else { fatalError("FAIL: \(title)") }
            count += 1; print("PASS: \(title)")
        }
        try Data().write(to: beat)
        try """
        #!/bin/sh
        if [ "$1" = "-g" ]; then
          if [ "$2" = "batt" ]; then
            /usr/bin/printf "Now drawing from 'AC Power'\\n -InternalBattery-0 80%%; charged\\n"
          else /usr/bin/printf ' SleepDisabled 1\\n'; fi
        fi
        """.write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        func launch(_ script: String, appleScript: Bool = false) throws -> (Int32, String) {
            let launcher = LidGuardScript.launch(script: script, token: token)
                .replacingOccurrences(of: "[ \"$(/usr/bin/id -u)\" = 0 ]", with: ":")
                .replacingOccurrences(of: "/private/var/run/fr.local.moka-launch.XXXXXX", with: tempLog.path)
                .replacingOccurrences(of: LidGuardScript.stateDirectory, with: state.path)
                .replacingOccurrences(of: "/usr/bin/pmset", with: fake.path)
            let process = Process(); let errors = Pipe()
            let command = "/bin/sh -p -c " + ShellEscaping.quote(launcher)
            process.executableURL = URL(fileURLWithPath: appleScript ? "/usr/bin/osascript" : "/bin/sh")
            process.arguments = appleScript ? ["-e", "do shell script " + ShellEscaping.appleScriptString(command)] : ["-p", "-c", launcher]
            process.standardOutput = FileHandle.nullDevice; process.standardError = errors
            try process.run()
            let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            process.waitUntilExit()
            return (process.terminationStatus, text)
        }
        let broken = try launch("/usr/bin/printf '%s\\n' 'fixture failure' >&2; exit 42")
        check(broken.0 != 0 && broken.1.contains("fixture failure") && broken.1.contains("MOKA_WORKER_EXIT"), "A failing background worker cannot return a false startup success")
        let malformed = try launch("if")
        check(malformed.0 != 0 && malformed.1.contains("MOKA_WORKER_EXIT"), "Worker syntax errors are reported by the launcher")
        let script = LidGuardScript.make(heartbeat: beat.path, token: token, parentPID: getpid(), reserve: 15)
        let complete = try launch(script, appleScript: CommandLine.arguments.contains("--applescript"))
        check(complete.0 == 0 && complete.1.isEmpty, "Complete launcher confirms the simulated watchdog")
        check((try? String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8)) == token, "Success means the actual token exists before the launcher returns")
        let pid = Int32(try String(contentsOf: state.appendingPathComponent("pid"), encoding: .utf8))!
        check(kill(pid, SIGHUP) == 0, "The simulated worker receives a launcher hangup")
        Thread.sleep(forTimeInterval: 0.2)
        check(kill(pid, 0) == 0 && FileManager.default.fileExists(atPath: state.appendingPathComponent("token").path), "The worker ignores hangup without macOS nohup")
        try FileManager.default.removeItem(at: beat)
        for _ in 0..<50 {
            if !FileManager.default.fileExists(atPath: state.path) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let result = (try? String(contentsOfFile: state.path + ".result", encoding: .utf8)).flatMap(LidGuardResult.init)
        check(!FileManager.default.fileExists(atPath: state.path) && result?.restored == true, "The child survives launcher exit and restores its simulated setting on stop")
        check(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix("launch.") }, "Temporary startup logs are removed")
        check(LidLaunchFailure.message(detail: "MOKA_NOT_ROOT").contains("droits administrateur"), "Missing privileges produce a precise message")
        check(LidLaunchFailure.message(detail: "MOKA_WORKER_EXIT\nfixture failure").contains("fixture failure"), "Worker diagnostics reach the UI")
        print("\(count) launcher tests passed; simulated power only" + (CommandLine.arguments.contains("--applescript") ? ", real AppleScript transport" : ""))
    }
}
