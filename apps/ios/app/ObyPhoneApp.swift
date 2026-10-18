import SwiftUI

/// Oby on iPhone: a client of the runner (docs/runner-api.md), so work goes on with the Mac closed.
/// Sangam's design, light or dark as the system is (Settings › Appearance), in three tabs: Home, the stage; Conversations with Oby; Settings.
@main
struct ObyPhoneApp: App {
    /// Holds the phone, so a notification tapped before Home appears still opens its job.
    @UIApplicationDelegateAdaptor(Notifications.self) private var notifications
    @State private var character = ObyCharacter(query: "embed&size=1.23")
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    @Environment(\.scenePhase) private var scenePhase

    private var phone: Phone { notifications.phone }

    var body: some Scene {
        WindowGroup {
            TabView(selection: Binding { phone.tab } set: { phone.tab = $0 }) {
                Tab("Home", systemImage: "house", value: PhoneTab.home) {
                    HomeView(character: character)
                }
                Tab("Conversations", systemImage: "bubble.left.and.bubble.right", value: PhoneTab.chat) {
                    ConversationsScreen()
                }
                Tab("Settings", systemImage: "gearshape", value: PhoneTab.settings) {
                    SettingsScreen()
                }
            }
            // iOS 26's bar: it steps aside while a thread scrolls.
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(Tokens.ink)
            .foregroundStyle(Tokens.text)
            .background(Tokens.bg)
            .preferredColorScheme(appearance.scheme)
            .environment(phone)
            .onChange(of: scenePhase, initial: true) { _, phase in
                // In the background: no connection and no drawing, so no battery spent.
                phase == .active ? phone.start() : phone.stop()
            }
            // Oby draws only while Home's stage shows.
            .onChange(of: scenePhase == .active && phone.tab == .home && phone.homePath.isEmpty, initial: true) { _, shown in
                character.pause(!shown)
            }
            // Leaving a tab mid-hold: the mic stops, as leaving Home always did.
            .onChange(of: phone.tab) { phone.cancelVoice() }
        }
        // A job ended while Oby was suspended (JobWaiter): say so on the Live Activity.
        .backgroundTask(.urlSession(JobWaiter.identifier)) { [phone] in await phone.catchUp() }
    }
}
