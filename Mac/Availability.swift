import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import Observation

/// Owns the Mac's idle-sleep assertion. Jobs always keep the Mac awake; the preference only
/// keeps it awake while external power is available.
@MainActor
@Observable
final class MacAvailability {
    static let setting = "runner.keepAvailable"
    enum State: Equatable, Sendable { case available, sleepingSoon }
    private(set) var state: State = .sleepingSoon
    private(set) var preventingSleep = false
    private(set) var keepAvailable: Bool
    private var assertion: IOPMAssertionID = 0
    private var powerConnected = true
    private var runningJobs = false

    init() {
        keepAvailable = UserDefaults.standard.object(forKey: Self.setting) as? Bool ?? true
        powerConnected = Self.isPowerConnected()
        update()
    }

    deinit { if preventingSleep { IOPMAssertionRelease(assertion) } }
    func setKeepAvailable(_ value: Bool) { keepAvailable = value; UserDefaults.standard.set(value, forKey: Self.setting); update() }
    func setPowerConnected(_ value: Bool) { powerConnected = value; update() }
    func setRunningJobs(_ value: Bool) {
        runningJobs = value
        powerConnected = Self.isPowerConnected()
        update()
    }
    var shouldPreventSleep: Bool { runningJobs || (keepAvailable && powerConnected) }
    var label: String { state == .available ? "Available" : "Sleeping soon" }

    private func update() {
        state = shouldPreventSleep ? .available : .sleepingSoon
        guard shouldPreventSleep != preventingSleep else { return }
        if shouldPreventSleep {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     "Oby keeps the Mac available for its runner" as CFString, &id)
            guard result == kIOReturnSuccess else { return }
            assertion = id
            preventingSleep = true
        } else {
            IOPMAssertionRelease(assertion)
            assertion = 0
            preventingSleep = false
        }
    }

    private static func isPowerConnected() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        return list.contains { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        }
    }
}
