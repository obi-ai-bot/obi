import AppKit
import IOKit.pwr_mgt
import IOKit.ps
import Observation

/// Owns the Mac's idle-sleep assertion. Jobs always keep the Mac awake; the preference only
/// keeps it awake while external power is available.
@MainActor
@Observable
final class MacAvailability {
    typealias AssertionCreator = @MainActor (CFString, IOPMAssertionLevel, CFString, UnsafeMutablePointer<IOPMAssertionID>) -> IOReturn
    typealias AssertionReleaser = @MainActor (IOPMAssertionID) -> IOReturn
    static let setting = "runner.keepAvailable"
    enum State: Equatable, Sendable { case available, sleepingSoon }
    private(set) var state: State = .sleepingSoon
    private(set) var preventingSleep = false
    private(set) var keepAvailable: Bool
    private var assertion: IOPMAssertionID = 0
    private var powerConnected = true
    private var runningJobs = false
    private var runnerEnabled: Bool
    private var powerSourceRunLoop: CFRunLoopSource?
    private let createAssertion: AssertionCreator
    private let releaseAssertion: AssertionReleaser
    private let defaults: UserDefaults
    private let powerSource: @MainActor () -> Bool

    init(createAssertion: @escaping AssertionCreator = MacAvailability.createAssertion,
         releaseAssertion: @escaping AssertionReleaser = IOPMAssertionRelease,
         defaults: UserDefaults = .standard,
         powerConnected: Bool? = nil,
         powerSource: @escaping @MainActor () -> Bool = MacAvailability.isPowerConnected) {
        self.createAssertion = createAssertion
        self.releaseAssertion = releaseAssertion
        self.defaults = defaults
        self.powerSource = powerSource
        let runnerEnabled = defaults.object(forKey: RunnerFeed.thisMacKey) as? Bool ?? false
        self.runnerEnabled = runnerEnabled
        self.keepAvailable = defaults.object(forKey: Self.setting) as? Bool ?? runnerEnabled
        self.powerConnected = powerConnected ?? powerSource()
        update()
    }

    isolated deinit {
        if let powerSourceRunLoop {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSourceRunLoop, .commonModes)
        }
        if preventingSleep { releaseAssertion(assertion) }
    }
    func setKeepAvailable(_ value: Bool) { keepAvailable = value; defaults.set(value, forKey: Self.setting); update() }
    func setRunnerEnabled(_ value: Bool) {
        runnerEnabled = value
        if defaults.object(forKey: Self.setting) == nil { keepAvailable = value }
        update()
    }
    func startMonitoring() {
        guard powerSourceRunLoop == nil else { return }
        powerSourceRunLoop = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let availability = Unmanaged<MacAvailability>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak availability] in
                guard let availability else { return }
                availability.setPowerConnected(availability.powerSource())
            }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue()
        if let powerSourceRunLoop {
            CFRunLoopAddSource(CFRunLoopGetMain(), powerSourceRunLoop, .commonModes)
        }
        setPowerConnected(powerSource())
    }
    func setPowerConnected(_ value: Bool) { powerConnected = value; update() }
    func setRunningJobs(_ value: Bool) {
        runningJobs = value
        powerConnected = powerSource()
        update()
    }
    var shouldPreventSleep: Bool { runningJobs || (keepAvailable && runnerEnabled && powerConnected) }
    var label: String { state == .available ? "Available" : "Sleeping soon" }

    private func update() {
        guard shouldPreventSleep != preventingSleep else {
            if !shouldPreventSleep { state = .sleepingSoon }
            return
        }
        if shouldPreventSleep {
            var id: IOPMAssertionID = 0
            let result = createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                         "Oby keeps the Mac available for its runner" as CFString, &id)
            guard result == kIOReturnSuccess else { state = .sleepingSoon; return }
            assertion = id
            preventingSleep = true
            state = .available
        } else {
            releaseAssertion(assertion)
            assertion = 0
            preventingSleep = false
            state = .sleepingSoon
        }
    }

    private static func createAssertion(_ type: CFString, _ level: IOPMAssertionLevel, _ name: CFString,
                                        _ id: UnsafeMutablePointer<IOPMAssertionID>) -> IOReturn {
        IOPMAssertionCreateWithName(type, level, name, id)
    }

    private static func isPowerConnected() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return true }
        return list.contains { source in
            (IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any])?[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
        }
    }
}
