import Foundation

final class GuardFixture {
    var date = Date()
    var record: LidGuardRecord?
    var result: LidGuardResult?
    var alive = true
    var systemDisabled: Bool? = false
    var completion: ((String?) -> Void)?
    var command = ""
    lazy var dependencies = LidGuardDependencies(now: { self.date }, record: { self.record }, result: { self.result }, alive: { _ in self.alive }, authorize: { self.command = $0; self.completion = $1 }, readSystem: { $0(self.systemDisabled) })
    var token: String {
        let expression = try! NSRegularExpression(pattern: "moka-lid-([A-F0-9-]{36})")
        let match = expression.firstMatch(in: command, range: NSRange(command.startIndex..., in: command))!
        return String(command[Range(match.range(at: 1), in: command)!])
    }
    func confirm(_ guardModel: LidGuard, previous: Bool = false) {
        record = .init(token: token, pid: 42, previousDisabled: previous)
        completion?(nil)
    }
    func finish(_ reason: String, previous: Bool = false, restored: Bool = true) {
        result = LidGuardResult(text: "\(token)\n\(reason)\n\(previous ? 1 : 0)\n\(restored ? 1 : 0)\n")
        record = nil
    }
}

@main enum LidStateTests {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ title: String) {
            guard value else { fatalError("FAIL: \(title)") }
            count += 1; print("PASS: \(title)")
        }
        func scenario(_ test: (LidGuard, GuardFixture, UserDefaults) -> Void) {
            let suite = "fr.local.moka.lid-tests.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            let fixture = GuardFixture()
            let model = LidGuard(defaults: defaults, dependencies: fixture.dependencies)
            defer { model.stop(); defaults.removePersistentDomain(forName: suite) }
            test(model, fixture, defaults)
        }
        scenario { model, fixture, _ in
            fixture.systemDisabled = true; model.refreshSystemState()
            check(model.unmanagedSleepDisabled && !model.active, "External disabled sleep is never presented as an owned lid session")
            model.start(reserve: 15)
            check(model.pending && !model.active && !model.unmanagedSleepDisabled, "Authorization pending is distinct from confirmed activity")
            fixture.completion?(nil)
            check(model.pending && !model.active, "Accepting a password alone cannot mark the mode active")
            fixture.date.addTimeInterval(9); model.pulse()
            check(!model.pending && !model.active && model.message?.contains("pas confirmé") == true, "Missing helper confirmation times out with a visible explanation")
        }
        scenario { model, fixture, defaults in
            model.start(reserve: 15); fixture.completion?("Activation annulée.")
            check(!model.pending && !model.active && model.message == "Activation annulée.", "Cancelled authorization leaves the toggle off with its reason")
            check(defaults.string(forKey: "lidLastDiagnostic") == model.message, "Last diagnostic survives relaunch")
        }
        scenario { model, fixture, _ in
            model.start(reserve: 15)
            model.stop(); fixture.completion?(nil)
            check(!model.needsPulse, "Late authorization after Stop cannot reactivate the UI")
            check(!FileManager.default.fileExists(atPath: FileManager.default.temporaryDirectory.appendingPathComponent("moka-lid-\(fixture.token)/heartbeat").path), "Stop removes the heartbeat before a late helper can enable sleep prevention")
        }
        scenario { model, fixture, _ in
            model.start(reserve: 15); fixture.confirm(model)
            check(model.active && !model.pending, "Matching live helper confirms the toggle")
            model.stop()
            check(model.stopping && !model.active, "Stop waits for the owned guard to restore the system")
            fixture.finish("stopped"); model.pulse()
            check(!model.stopping && model.message?.contains("rétabli") == true, "Restoration is confirmed explicitly")
        }
        scenario { model, fixture, _ in
            model.start(reserve: 15); fixture.confirm(model, previous: true)
            check(model.previousDisabled && model.active, "Pre-existing disabled sleep is retained as part of the session state")
            model.stop(); fixture.finish("stopped", previous: true); model.pulse()
            check(model.message?.contains("le reste") == true, "Restoring an original value of one does not claim sleep was re-enabled")
        }
        scenario { model, fixture, _ in
            model.start(reserve: 15); fixture.confirm(model)
            fixture.alive = false; model.pulse()
            check(!model.active && model.message?.contains("interrompue") == true, "Dead guard cannot leave a falsely checked toggle")
        }
        scenario { model, fixture, _ in
            model.start(reserve: 15); fixture.confirm(model)
            fixture.result = LidGuardResult(text: "unrelated\nbattery\n0\n1\n"); model.pulse()
            check(model.active, "A different session's result cannot stop the current UI")
            fixture.finish("battery"); model.pulse()
            check(!model.active && model.message?.contains("batterie") == true, "Battery stop is explained at the control")
        }
        scenario { model, fixture, _ in
            model.start(reserve: 15); fixture.confirm(model)
            model.stop(); fixture.finish("restore_failed", restored: false); model.pulse()
            check(model.restorationFailed && !model.stopping && model.message?.contains("échoué") == true, "Restoration failure stays explicit and allows an authorized recovery attempt")
        }
        scenario { model, fixture, _ in
            model.start(reserve: 15)
            fixture.record = .init(token: "other-session", pid: 42, previousDisabled: false)
            fixture.completion?(nil)
            fixture.date.addTimeInterval(9); model.pulse()
            check(!model.active && !model.pending, "Another live guard does not confirm this session")
        }
        check(LidGuardResult(text: "bad\nrecord") == nil, "Truncated diagnostic records are rejected")
        print("\(count) lid state tests passed; no administrator prompts or real power changes")
    }
}
