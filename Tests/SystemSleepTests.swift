import Foundation

@main enum SystemSleepTests {
    static func main() {
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            precondition(condition, name); count += 1; print("PASS: \(name)")
        }
        for disabled in [false, true] {
            let output = "System-wide power settings:\n SleepDisabled\t\t\(disabled ? 1 : 0)\nCurrently in use:\n sleep 0\n"
            check(SystemSleep.read(pmset: { output }, registry: {
                preconditionFailure("A valid configured value must not be replaced by the kernel value")
            }) == disabled, "Valid pmset value \(disabled) remains authoritative")
            check(SystemSleep.read(pmset: { nil }, registry: { disabled ? kCFBooleanTrue : kCFBooleanFalse }) == disabled,
                  "Failed startup command recovers explicit kernel value \(disabled)")
            check(SystemSleep.read(pmset: { "System-wide power settings:\nCurrently in use:\n sleep 0\n" },
                                   registry: { disabled ? kCFBooleanTrue : kCFBooleanFalse }) == disabled,
                  "Omitted pmset key recovers explicit kernel value \(disabled)")
        }
        for output in ["", "SleepDisabled", "SleepDisabled unknown", "SleepDisabled 2"] {
            check(SystemSleep.read(pmset: { output }, registry: { nil }) == nil,
                  "Unreadable state remains unknown: \(output)")
        }
        for invalid: CFTypeRef in ["false" as CFString, NSNumber(value: 0), NSNumber(value: 1)] {
            check(SystemSleep.read(pmset: { nil }, registry: { invalid }) == nil,
                  "A non-boolean kernel property cannot authorize a session")
        }
        check(SystemSleep.read(pmset: { nil }, registry: { nil }) == nil,
              "Both sources unavailable fail closed")
        for original in [false, true] {
            var kernelState = original
            var journal: Bool?
            let engine = SessionEngine(environment: .init(
                now: { 0 }, eligible: { _ in true }, tooHot: { false }, legacyBusy: { false },
                readSleep: { SystemSleep.read(pmset: { nil }, registry: {
                    kernelState ? kCFBooleanTrue : kCFBooleanFalse
                }) }, writeSleep: { kernelState = $0; return true },
                loadJournal: { nil }, saveJournal: { journal = $0 }, clearJournal: { journal = nil }))
            let owner = UUID()
            check(engine.begin(owner: owner, reserve: 20).active && kernelState && journal == original,
                  "Failed pmset read still journals the explicit original state \(original) before activation")
            _ = engine.end(owner: owner)
            check(kernelState == original && journal == nil && !engine.state.restorationFailed,
                  "Kernel fallback restores the original state \(original) after the session")
        }
        if CommandLine.arguments.contains("--integration") {
            let current = SystemSleep.read()
            let fallback = SystemSleep.read(pmset: { nil }, registry: SystemSleep.registryValue)
            check(current != nil && current == fallback,
                  "Real macOS kernel fallback matches the configured sleep state without writing it")
        }
        print("\(count) system-sleep tests passed")
    }
}
