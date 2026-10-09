import ServiceManagement
import SwiftUI

@main
struct ObyApp: App {
    @NSApplicationDelegateAdaptor private var app: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            Button("Open Oby") { app.island.open() }
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Oby") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: .obyMenuBarIcon)
                .accessibilityLabel("Oby")
        }

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let island = IslandController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hosting the unit tests: no island, and no fight with the Oby that's already running.
        guard NSClassFromString("XCTestCase") == nil else { return }
        // A pipe to an agent that just exited must not take Oby down with it.
        signal(SIGPIPE, SIG_IGN)
        Task.detached { _ = Shell.environment }
        // One Oby at a time: a second launch quietly leaves the first one in charge.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != .current }
        guard others.isEmpty else { NSApp.terminate(nil); return }
        island.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        island.desk.quit()
    }
}

struct SettingsView: View {
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var problem: String?

    var body: some View {
        Form {
            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        problem = nil
                    } catch {
                        problem = error.localizedDescription
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear { NSApp.activate() }
    }
}

extension NSImage {
    /// Sangam's menu bar icon: the soft block with two eyes, as a template image.
    static let obyMenuBarIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3, width: 15, height: 12.1), xRadius: 5, yRadius: 5).fill()
            context.compositingOperation = .clear
            for x in [4.9, 11.1] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 8, width: 2, height: 3.8), xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
