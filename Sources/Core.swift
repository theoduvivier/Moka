import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import IOKit.ps

enum MacHardware {
    /// IOPM.h: a boolean exists for either lid position; absence means no lid.
    /// This is a hardware capability, independent of the current power source.
    static let hasLid: Bool = {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(root) }
        guard let state = IORegistryEntryCreateCFProperty(root, kAppleClamshellStateKey as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue() else { return false }
        return CFGetTypeID(state) == CFBooleanGetTypeID()
    }()
}

struct PowerSnapshot: Equatable {
    var onBattery: Bool
    var percentage: Int?
    static func read() -> PowerSnapshot {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return .init(onBattery: false, percentage: nil)
        }
        let provider = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = provider == kIOPSBatteryPowerValue
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let current = d[kIOPSCurrentCapacityKey] as? Int
            let maximum = d[kIOPSMaxCapacityKey] as? Int
            let percentage = current.flatMap { c in maximum.flatMap { $0 > 0 ? min(100, max(0, c * 100 / $0)) : nil } }
            return .init(onBattery: onBattery, percentage: percentage)
        }
        return .init(onBattery: onBattery, percentage: nil)
    }
}

enum SessionPolicy {
    static func timerInterval(enabled: Bool, lidNeedsPulse: Bool, panelVisible: Bool) -> TimeInterval {
        if panelVisible && enabled { return 1 }
        return enabled || lidNeedsPulse || panelVisible ? 5 : 0
    }
    static func reachedReserve(power: PowerSnapshot, reserve: Int) -> Bool {
        power.onBattery && power.percentage.map { $0 <= reserve } == true
    }

    /// A passive elapsed counter; sessions no longer have a duration limit.
    static func clock(startedAt: Date?, now: Date) -> String {
        let interval = startedAt.map { floor(now.timeIntervalSince($0)) } ?? 0
        let seconds = max(0, Int(interval))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, seconds % 3600 / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

struct MokaError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class SleepAssertions {
    private var ids: [IOPMAssertionID] = []
    private var displayEnabled: Bool?
    var isActive: Bool { !ids.isEmpty }
    func activate(display: Bool) throws {
        if displayEnabled == display && isActive { return }
        var fresh: [IOPMAssertionID] = []
        let types = display ? [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep] : [kIOPMAssertionTypePreventUserIdleSystemSleep]
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), "Moka — session de travail" as CFString, &id)
            guard result == kIOReturnSuccess else {
                fresh.forEach { IOPMAssertionRelease($0) }
                throw MokaError(message: "macOS n’a pas pu maintenir le Mac éveillé (\(result)).")
            }
            fresh.append(id)
        }
        release()
        ids = fresh
        displayEnabled = display
    }
    func release() {
        ids.forEach { IOPMAssertionRelease($0) }
        ids.removeAll()
        displayEnabled = nil
    }
    deinit { release() }
}

enum ShellEscaping {
    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func appleScriptString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

enum MenuGeometry {
    static func frame(anchor: CGRect, visible: CGRect, preferredHeight: CGFloat = 470) -> CGRect {
        let width = min(360, max(1, visible.width - 16))
        let height = min(preferredHeight, max(1, visible.height - 16))
        let x = max(visible.minX + 8, min(anchor.midX - width / 2, visible.maxX - width - 8))
        let top = min(anchor.minY - 8, visible.maxY - 8)
        let y = max(visible.minY + 8, top - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct StatusIconFrame {
    var fill: Double
    var scale: Double
}

enum StatusProtectionIndicator: Equatable {
    case inactive, awake, lidWarning
    static func resolve(awake: Bool, lidActive: Bool, lidStopping: Bool, restorationFailed: Bool) -> Self {
        if lidActive || lidStopping || restorationFailed { return .lidWarning }
        return awake ? .awake : .inactive
    }
}

/// One short transition, starting at the currently displayed frame so rapid
/// reversals stay continuous. The small contraction never accumulates.
struct StatusIconTransition {
    let from: StatusIconFrame
    let active: Bool
    let reduceMotion: Bool

    func frame(at progress: Double) -> StatusIconFrame {
        let p = min(1, max(0, progress))
        let eased = p * p * (3 - 2 * p)
        let target = active ? 1.0 : 0.0
        let fill = from.fill + (target - from.fill) * eased
        let contraction = active ? 0.10 : 0.06
        let remainingContraction = max(0, contraction - (1 - from.scale))
        let scale = reduceMotion ? 1 : from.scale + (1 - from.scale) * eased - remainingContraction * sin(.pi * p)
        return StatusIconFrame(fill: fill, scale: scale)
    }
}
