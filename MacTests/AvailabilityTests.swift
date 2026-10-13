import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Oby

@MainActor
struct AvailabilityTests {
    @Test func runningJobsTakeAndReleaseTheAssertion() {
        var created = 0
        var released = 0
        let defaults = UserDefaults(suiteName: "com.deskree.oby.availability-(UUID().uuidString)")!
        let availability = MacAvailability(
            createAssertion: { _, _, _, id in
                created += 1
                id.pointee = 42
                return kIOReturnSuccess
            },
            releaseAssertion: { _ in
                released += 1
                return kIOReturnSuccess
            }, defaults: defaults, powerConnected: false, powerSource: { false })
        availability.setKeepAvailable(false)
        availability.setRunningJobs(true)
        #expect(created == 1)
        #expect(availability.preventingSleep)
        #expect(availability.label == "Available")
        availability.setRunningJobs(false)
        #expect(released == 1)
        #expect(!availability.preventingSleep)
        #expect(availability.label == "Sleeping soon")
    }

    @Test func failedAssertionIsReportedAsSleepingSoon() {
        let defaults = UserDefaults(suiteName: "com.deskree.oby.availability-(UUID().uuidString)")!
        let availability = MacAvailability(createAssertion: { _, _, _, _ in kIOReturnError }, defaults: defaults, powerConnected: false, powerSource: { false })
        availability.setKeepAvailable(false)
        availability.setRunningJobs(true)
        #expect(!availability.preventingSleep)
        #expect(availability.label == "Sleeping soon")
    }
}
