import AppKit
import IOKit.pwr_mgt

@main
struct SessionTests {
    static func main() throws {
        _ = NSApplication.shared
        let suite = "fr.local.moka.simple-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "keepDisplayOn")
        defaults.set(true, forKey: "usePhone")
        defaults.set("Old phone", forKey: "phoneSSID")
        defaults.set(false, forKey: "allowBattery")
        defaults.set(25, forKey: "duration")
        defaults.set(15, forKey: "reserve")
        var snapshot = PowerSnapshot(onBattery: true, percentage: 80)
        var thermal = ProcessInfo.ThermalState.nominal
        let model = AppModel(defaults: defaults, readPower: { snapshot }, readThermal: { thermal })
        defer { model.shutdown() }
        var count = 0
        func check(_ condition: Bool, _ label: String) {
            guard condition else { fatalError("FAIL: \(label)") }
            count += 1
            print("PASS: \(label)")
        }
        func ownTypes() -> [String] {
            var value: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&value) == kIOReturnSuccess,
                  let all = value?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
                  let own = all[NSNumber(value: getpid())] else { return [] }
            return own.compactMap { $0[kIOPMAssertionTypeKey] as? String }
        }
        check(!model.enabled && !model.awake, "Launch never starts a session automatically")
        model.start()
        check(model.enabled && model.awake, "One action starts a session despite removed legacy preferences")
        check(ownTypes().contains("PreventUserIdleSystemSleep"), "Session holds the actual idle-sleep assertion")
        check(!ownTypes().contains("PreventUserIdleDisplaySleep"), "The screen may turn off even with a legacy display preference")
        let firstStart = model.startedAt
        model.start()
        check(model.startedAt == firstStart, "Repeated Start is idempotent")
        snapshot.percentage = 16
        model.tick(refresh: true)
        check(model.enabled, "Session continues above the selected reserve")
        snapshot.percentage = 15
        model.tick(refresh: true)
        check(!model.enabled && !model.awake && model.startedAt == nil, "Reaching the reserve ends the session instead of pausing it")
        check(!ownTypes().contains("PreventUserIdleSystemSleep"), "Battery cutoff releases the native assertion")
        check(model.notice?.contains("15 %") == true, "Automatic stop explains the measured battery level")
        snapshot = .init(onBattery: false, percentage: 15)
        model.tick(refresh: true)
        check(!model.enabled, "Connecting power never silently restarts a stopped session")
        model.start()
        check(model.enabled, "An explicit start works on AC power below the reserve")
        model.stop()
        snapshot = .init(onBattery: true, percentage: 10)
        model.start()
        check(!model.enabled && model.notice != nil, "Low battery cannot start a session")
        snapshot = .init(onBattery: true, percentage: 20)
        model.start()
        model.reserve = 25
        check(!model.enabled, "Raising the cutoff above the current battery stops immediately")
        model.reserve = 5
        model.start()
        check(model.enabled && model.reserve == 5, "Lowering the cutoff allows a new explicit session")
        model.stop()
        check(!ownTypes().contains("PreventUserIdleSystemSleep"), "Manual stop releases the assertion")
        check(defaults.integer(forKey: "reserve") == 5, "Selected battery cutoff persists")
        check(SessionPolicy.timerInterval(enabled: true, lidNeedsPulse: true, panelVisible: false) == 5, "Hidden session avoids one-second wakeups")
        check(SessionPolicy.timerInterval(enabled: false, lidNeedsPulse: false, panelVisible: false) == 0, "Idle hidden application has no polling timer")
        check(SessionPolicy.timerInterval(enabled: true, lidNeedsPulse: true, panelVisible: true) == 1, "Visible elapsed timer stays responsive")
        thermal = .serious
        model.start()
        check(!model.enabled, "Hot Mac cannot start a wake session")
        thermal = .nominal; model.start(); thermal = .serious; model.tick(refresh: true)
        check(!model.enabled && !ownTypes().contains("PreventUserIdleSystemSleep"), "Strong heat releases wake assertion")
        print("\(count) simple-session tests passed")
    }
}
