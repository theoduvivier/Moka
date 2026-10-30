import Foundation

final class Rig {
    var now: TimeInterval = 0
    var level = 80
    var hot = false
    var legacy = false
    var sleep: Bool? = false
    var journal: Bool?
    var failWrite = false
    var failSave = false
    var corrupt = false
    var writes: [Bool] = []
    lazy var engine = SessionEngine(environment: environment)
    var environment: SessionEnvironment {
        .init(now: { self.now }, eligible: { self.level > $0 }, tooHot: { self.hot }, legacyBusy: { self.legacy },
              readSleep: { self.sleep }, writeSleep: { value in
                  self.writes.append(value)
                  if self.failWrite { return false }
                  self.sleep = value; return true
              }, loadJournal: {
                  if self.corrupt { throw NSError(domain: "test", code: 1) }
                  return self.journal
              }, saveJournal: {
                  if self.failSave { throw NSError(domain: "test", code: 2) }
                  self.journal = $0
              }, clearJournal: { self.journal = nil })
    }
}

@main enum HelperTests {
    static func main() throws {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); count += 1; print("PASS: \(name)")
        }
        let a = UUID(), b = UUID()
        do {
            let r = Rig()
            check(!r.engine.needsTick, "Idle helper needs no polling timer")
            check(r.engine.begin(owner: a, reserve: 20).active && r.sleep == true && r.journal == false, "Start journals original setting before changing it")
            check(!r.engine.begin(owner: b, reserve: 20).active, "A second connection cannot take over")
            _ = r.engine.end(owner: b)
            check(r.engine.state.active, "Another connection cannot stop the owner's session")
            r.engine.disconnect(owner: b)
            check(r.engine.state.active, "Unrelated client disconnection does not stop session")
            _ = r.engine.end(owner: a)
            check(r.sleep == false && r.journal == nil && !r.engine.needsTick, "Stop restores and erases journal")
        }
        do {
            let r = Rig(); r.sleep = true
            _ = r.engine.begin(owner: a, reserve: 20); _ = r.engine.end(owner: a)
            check(r.sleep == true && r.engine.state.message.contains("déjà"), "Preexisting disable-sleep is preserved and explained")
        }
        for value in [-1, 0, 4, 51, Int.max] {
            let r = Rig()
            check(!r.engine.begin(owner: a, reserve: value).active && r.writes.isEmpty, "Reject invalid reserve \(value) without a write")
        }
        do {
            let r = Rig(); r.failSave = true
            check(!r.engine.begin(owner: a, reserve: 20).active && r.writes.isEmpty, "No setting change if journal cannot be saved")
        }
        do {
            let r = Rig(); r.sleep = nil
            check(!r.engine.begin(owner: a, reserve: 20).active && r.writes.isEmpty, "Unknown original setting fails closed")
        }
        do {
            let r = Rig(); r.legacy = true
            check(!r.engine.begin(owner: a, reserve: 20).active && r.writes.isEmpty, "Legacy watchdog cannot overlap new service")
        }
        do {
            let r = Rig(); r.hot = true
            check(!r.engine.begin(owner: a, reserve: 20).active, "Hot Mac cannot start lid mode")
        }
        do {
            let r = Rig(); _ = r.engine.begin(owner: a, reserve: 20)
            r.now = 24; r.engine.tick()
            check(r.engine.state.active, "Lease survives a short scheduling delay")
            r.now = 25
            check(!r.engine.renew(owner: a, reserve: 20).active && r.sleep == false, "Late heartbeat cannot revive an expired lease")
        }
        do {
            let r = Rig(); _ = r.engine.begin(owner: a, reserve: 20)
            r.level = 30
            check(!r.engine.renew(owner: a, reserve: 30).active && r.sleep == false, "New reserve is enforced immediately, including equality")
        }
        do {
            let r = Rig(); _ = r.engine.begin(owner: a, reserve: 20)
            r.hot = true; r.engine.tick()
            check(!r.engine.state.active && r.sleep == false, "Strong heat stops lid mode independently of the app")
        }
        do {
            let r = Rig(); _ = r.engine.begin(owner: a, reserve: 20)
            for t in stride(from: 20, to: 14_400, by: 20) {
                r.now = Double(t); _ = r.engine.begin(owner: a, reserve: 20)
            }
            r.now = 14_400; _ = r.engine.renew(owner: a, reserve: 20)
            check(!r.engine.state.active && r.sleep == false, "Idempotent starts cannot extend the four-hour cap")
        }
        do {
            let r = Rig(); _ = r.engine.begin(owner: a, reserve: 20)
            r.engine.disconnect(owner: a)
            check(r.sleep == false && !r.engine.state.active, "App crash/disconnection restores immediately")
        }
        do {
            let r = Rig(); r.journal = false; r.sleep = true
            check(!r.engine.state.restorationFailed && r.sleep == false && r.journal == nil, "Helper restart recovers the durable journal")
        }
        do {
            let r = Rig(); r.corrupt = true
            check(r.engine.begin(owner: a, reserve: 20).restorationFailed && r.writes.isEmpty, "Corrupt journal never guesses a system value")
        }
        do {
            let r = Rig(); _ = r.engine.begin(owner: a, reserve: 20)
            r.failWrite = true
            check(r.engine.end(owner: a).restorationFailed && r.journal != nil, "Failed restoration retains journal and visible failure")
            check(!r.engine.begin(owner: a, reserve: 20).active, "Failed restoration blocks another session")
            r.failWrite = false; r.engine.tick()
            check(!r.engine.state.restorationFailed && r.sleep == false && r.journal == nil, "Restoration retries recover automatically")
        }
        do {
            let r = Rig(); r.sleep = true; _ = r.engine.begin(owner: a, reserve: 20)
            r.sleep = false; _ = r.engine.end(owner: a)
            check(r.sleep == false, "External re-enabling of sleep is never overwritten")
        }
        do {
            let r = Rig(); _ = r.engine.begin(owner: a, reserve: 20); r.engine.shutdown()
            check(r.sleep == false && r.journal == nil, "Daemon shutdown restores before exit")
        }
        check(HelperStatus(dictionary: ["version": 999]) == nil, "Incompatible replies fail closed")
        check(HelperStatus(dictionary: HelperStatus(active: true).dictionary)?.active == true, "Protocol status survives property-list serialization")
        print("\(count) helper engine tests passed")
    }
}
