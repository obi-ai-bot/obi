import SwiftUI

/// Oby on iPhone: a client of the runner (docs/runner-api.md), so work goes on with the Mac closed.
@main
struct ObyPhoneApp: App {
    @State private var phone = Phone()
    @State private var character = ObyCharacter()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            HomeView(character: character)
                .environment(phone)
                .preferredColorScheme(.dark)
                .tint(.white)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // In the background: no connection and no drawing, so no battery spent.
                    let active = phase == .active
                    active ? phone.start() : phone.stop()
                    character.pause(!active)
                }
        }
    }
}
