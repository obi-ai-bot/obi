import SwiftUI

/// Oby on iPhone: a client of the runner (docs/runner-api.md), so work goes on with the Mac closed.
/// Three tabs (#11): Home, the glance; Chat, the one thread with Oby every device shares; Settings.
@main
struct ObyPhoneApp: App {
    /// Holds the phone, so a notification tapped before Home appears still opens its job.
    @UIApplicationDelegateAdaptor(Notifications.self) private var notifications
    @State private var character = ObyCharacter()
    @Environment(\.scenePhase) private var scenePhase

    private var phone: Phone { notifications.phone }

    var body: some Scene {
        WindowGroup {
            TabView(selection: Binding { phone.tab } set: { phone.tab = $0 }) {
                Tab("Home", systemImage: "house", value: PhoneTab.home) {
                    HomeView(character: character)
                }
                Tab("Chat", systemImage: "bubble.left.and.text.bubble.right", value: PhoneTab.chat) {
                    ChatScreen()
                }
                Tab("Settings", systemImage: "gearshape", value: PhoneTab.settings) {
                    SettingsScreen()
                }
            }
            // iOS 26's bar: it steps aside while the thread scrolls.
            .tabBarMinimizeBehavior(.onScrollDown)
            .environment(phone)
            .onChange(of: scenePhase, initial: true) { _, phase in
                // In the background: no connection and no drawing, so no battery spent.
                let active = phase == .active
                active ? phone.start() : phone.stop()
                character.pause(!active)
            }
            // Leaving a tab mid-hold: the mic stops, as leaving Home always did.
            .onChange(of: phone.tab) { phone.cancelVoice() }
        }
        // A job ended while Oby was suspended (JobWaiter): say so on the Live Activity.
        .backgroundTask(.urlSession(JobWaiter.identifier)) { [phone] in await phone.catchUp() }
    }
}
