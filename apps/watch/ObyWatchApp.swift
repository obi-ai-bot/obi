import SwiftUI

/// Oby on Apple Watch: what needs you, Publish with the crown, and talking to Oby, through the
/// iPhone, or through the runner's Watch API when the phone is out of reach (apps/watch/README.md).
@main
struct ObyWatchApp: App {
    /// Holds the watch's model, so a notification tapped before Home appears still opens its job.
    @WKApplicationDelegateAdaptor(WatchNotifications.self) private var notifications
    @Environment(\.scenePhase) private var scenePhase

    private var watch: Watch { notifications.watch }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(watch)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Back on the wrist: the latest jobs, not the ones the phone last pushed.
                    // Without the phone, the runner's events stream only while Oby is on screen.
                    watch.onScreen(phase == .active)
                }
        }
    }
}
