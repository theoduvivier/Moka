import Foundation
import CoreGraphics
import IOKit.pwr_mgt

@main
enum CoreTests {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ title: String) {
            guard value else { fatalError("FAIL: \(title)") }
            count += 1
            print("PASS: \(title)")
        }
        check(!SessionPolicy.reachedReserve(power: .init(onBattery: false, percentage: 10), reserve: 15), "AC power is allowed below the reserve")
        check(SessionPolicy.reachedReserve(power: .init(onBattery: true, percentage: 15), reserve: 15), "Reserve includes the threshold")
        check(!SessionPolicy.reachedReserve(power: .init(onBattery: true, percentage: 16), reserve: 15), "Battery above reserve is allowed")
        let date = Date(timeIntervalSince1970: 10000)
        check(SessionPolicy.clock(startedAt: date, now: date.addingTimeInterval(61.9)) == "01:01", "Elapsed counter shows complete seconds")
        check(SessionPolicy.clock(startedAt: date, now: date.addingTimeInterval(3601)) == "1:00:01", "Elapsed counter keeps seconds across an hour")
        check(SessionPolicy.clock(startedAt: date, now: date.addingTimeInterval(-10)) == "00:00", "Clock changes cannot display negative elapsed time")
        check(StatusProtectionIndicator.resolve(awake: true, lidActive: false, lidStopping: false, restorationFailed: false) == .awake, "Ordinary wake protection keeps its green indicator")
        check(StatusProtectionIndicator.resolve(awake: true, lidActive: true, lidStopping: false, restorationFailed: false) == .lidWarning, "Confirmed lid mode takes priority over ordinary wake protection")
        check(StatusProtectionIndicator.resolve(awake: false, lidActive: false, lidStopping: true, restorationFailed: false) == .lidWarning, "Lid warning remains during restoration after the session stops")
        check(StatusProtectionIndicator.resolve(awake: false, lidActive: false, lidStopping: false, restorationFailed: true) == .lidWarning, "Unconfirmed restoration cannot clear the red warning")
        check(StatusProtectionIndicator.resolve(awake: false, lidActive: false, lidStopping: false, restorationFailed: false) == .inactive, "A confirmed stop clears both indicators")
        let iconRest = StatusIconFrame(fill: 0, scale: 1)
        let iconOn = StatusIconTransition(from: iconRest, active: true, reduceMotion: false)
        let iconMiddle = iconOn.frame(at: 0.5)
        check(iconOn.frame(at: 0).fill == 0 && iconOn.frame(at: 1).fill == 1 && iconOn.frame(at: 1).scale == 1, "Icon activation starts and ends at the exact states")
        check(iconMiddle.scale < 1 && iconMiddle.fill > 0 && iconMiddle.fill < 1, "Icon contracts once while its fill transitions")
        let iconReverse = StatusIconTransition(from: iconMiddle, active: false, reduceMotion: false)
        check(iconReverse.frame(at: 0).fill == iconMiddle.fill && iconReverse.frame(at: 0).scale == iconMiddle.scale, "A quick reversal starts at the currently displayed icon")
        check(iconReverse.frame(at: 1).fill == 0 && iconReverse.frame(at: 1).scale == 1, "Deactivation settles into the outline at full size")
        var interruptedFrame = iconRest
        var iconBoundsValid = true
        for index in 0..<120 {
            let transition = StatusIconTransition(from: interruptedFrame, active: index % 2 == 0, reduceMotion: false)
            for step in 0...60 {
                let frame = transition.frame(at: Double(step) / 60)
                iconBoundsValid = iconBoundsValid && (0...1).contains(frame.fill) && (0.899...1.001).contains(frame.scale)
            }
            interruptedFrame = transition.frame(at: 0.23)
        }
        check(iconBoundsValid, "Repeated reversals never enlarge the icon or accumulate contraction")
        let reducedIcon = StatusIconTransition(from: iconMiddle, active: false, reduceMotion: true)
        check((0...60).allSatisfy { reducedIcon.frame(at: Double($0)/60).scale == 1 }, "Reduce Motion keeps the icon still throughout its fade")
        check(iconOn.frame(at: -1).fill == 0 && iconOn.frame(at: 2).fill == 1, "Late animation frames clamp to the intended state")
        for height in [480.0, 620.0, 800.0, 1080.0] {
            let visible = CGRect(x: -1280, y: 40, width: 1280, height: height)
            let frame = MenuGeometry.frame(anchor: CGRect(x: -45, y: height+40, width: 24, height: 22), visible: visible)
            check(visible.contains(frame), "Menu remains on screen at \(Int(height))pt, including secondary display")
        }
        let malicious = "a'b; $(touch /tmp/should-not-exist) `id`\nfin"
        let process = Process(); let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s " + ShellEscaping.quote(malicious)]
        process.standardOutput = output
        try process.run(); process.waitUntilExit()
        check(String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) == malicious, "Shell arguments are literal, including metacharacters")
        if CommandLine.arguments.contains("--integration") {
            let assertions = SleepAssertions()
            try assertions.activate(display: false)
            check(assertions.isActive, "Native idle-sleep assertion created")
            func ownTypes() -> [String] {
                var unmanaged: Unmanaged<CFDictionary>?
                guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
                      let values = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]],
                      let own = values[NSNumber(value: getpid())] else { return [] }
                return own.compactMap { $0[kIOPMAssertionTypeKey] as? String }
            }
            check(ownTypes().contains("PreventUserIdleSystemSleep"), "macOS reports the system assertion")
            try assertions.activate(display: true)
            check(ownTypes().contains("PreventUserIdleDisplaySleep"), "Display mode creates display assertion")
            try assertions.activate(display: false)
            check(!ownTypes().contains("PreventUserIdleDisplaySleep"), "Changing mode releases display assertion")
            assertions.release()
            check(ownTypes().isEmpty, "Stopping releases all process assertions")
        }
        print("\(count) tests passed")
    }
}
