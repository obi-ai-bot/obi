import SwiftUI

/// Oby on iPhone: a client of the runner (docs/runner-api.md), so work goes on with the Mac closed.
@main
struct ObyPhoneApp: App {
    /// Holds the phone, so a notification tapped before Home appears still opens its job.
    @UIApplicationDelegateAdaptor(Notifications.self) private var notifications
    @State private var character = ObyCharacter()
    @Environment(\.scenePhase) private var scenePhase

    private var phone: Phone { notifications.phone }

    var body: some Scene {
        WindowGroup {
            HomeView(character: character)
                .environment(phone)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // In the background: no connection and no drawing, so no battery spent.
                    let active = phase == .active
                    active ? phone.start() : phone.stop()
                    character.pause(!active)
                }
        }
        // A job ended while Oby was suspended (JobWaiter): say so on the Live Activity.
        .backgroundTask(.urlSession(JobWaiter.identifier)) { [phone] in await phone.catchUp() }
    }
}
