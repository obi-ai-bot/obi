import AppKit
import SwiftUI
import UserNotifications

/// The quick settings surface in the notch: one short label per control, grouped in cards with the
/// same row height and spacing. What needs more words is a tooltip; the full Mac and iPhone settings
/// (Mac/Settings.swift) are one tap away for anything uncommon.
struct IslandSettings: View {
    let model: IslandModel
    @AppStorage(Speaker.setting) private var speaks = true
    @AppStorage(MacChecks.appleSetting) private var buildAgents = true
    @AppStorage(VoiceSettings.language) private var language = "system"
    @State private var alerts: UNAuthorizationStatus?

    private var desk: Desk { model.desk }
    private var feed: RunnerFeed { model.feed }

    /// The rows' height, the gap between rows, and the gap between cards: the same everywhere.
    nonisolated enum Metrics {
        static let row: CGFloat = 28
        static let rowGap: CGFloat = 4
        static let cardGap: CGFloat = 10
        static let cardPadding: CGFloat = 12
        /// Room under the last card, so it scrolls clear of the island's rounded corners.
        static let bottom: CGFloat = 14
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.cardGap) {
                accounts
                thisMac
                runner
                IslandPermissions(runner: feed.runner, defaultMode: feed.defaultMode, setDefault: feed.setDefaultMode)
                voice
                notifications
                Button { SettingsSelection.open(.general) } label: {
                    Label("More settings", systemImage: "arrow.up.right.square")
                        .frame(maxWidth: .infinity, minHeight: Metrics.row, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.horizontal, Metrics.cardPadding)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 4)
        }
        .contentMargins(.bottom, Metrics.bottom, for: .scrollContent)
        .scrollIndicators(.hidden)
        .frame(maxHeight: 390)
        .accessibilityLabel("Quick Settings")
    }

    private var accounts: some View {
        IslandCard("Accounts") {
            if desk.accounts.accounts.isEmpty && feed.accounts.isEmpty {
                Text("None yet").foregroundStyle(OBYStyle.secondary).frame(minHeight: Metrics.row)
            }
            usage(desk.accounts.accounts, place: feed.runner == nil ? nil : "This Mac") { state, on in
                _ = desk.liftReserve(state.account.id, on)
            }
            if let runner = feed.runner {
                usage(feed.accounts, place: feed.name) { state, on in
                    _ = try await runner.liftReserve(state.account.id, on)
                }
            }
        }
    }

    /// Each account's usage card, under the place it runs when there are two.
    @ViewBuilder private func usage(_ items: [AccountState], place: String?,
                                    lift: @escaping @MainActor (AccountState, Bool) async throws -> Void) -> some View {
        if !items.isEmpty {
            if let place { Text(place).font(OBYStyle.caption).foregroundStyle(OBYStyle.secondary) }
            ForEach(items, id: \.account.id) { state in
                UsageCard(snapshot: state.usage)
                ReserveSwitch(snapshot: state.usage) { on in try await lift(state, on) }
            }
        }
    }

    private var runner: some View {
        IslandCard("Runner") {
            IslandRow("Status") { Text(feed.connection.status(host: feed.name)).foregroundStyle(OBYStyle.secondary) }
            IslandRow("Version") { Text(feed.version ?? "Unknown").foregroundStyle(OBYStyle.secondary) }
            IslandRow("Test on this Mac", help: "Build and test the agents' work on this Mac") {
                Toggle("Test on this Mac", isOn: $buildAgents).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
        }
    }

    private var thisMac: some View {
        IslandCard("This Mac") {
            IslandRow("Keep available", help: "Prevent idle sleep while This Mac is enabled") {
                Toggle("Keep available", isOn: Binding(get: { model.availability.keepAvailable }, set: model.availability.setKeepAvailable))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            IslandRow("Availability") { Text(model.availability.label).foregroundStyle(OBYStyle.secondary) }
        }
    }

    private var voice: some View {
        IslandCard("Voice") {
            IslandRow("Speak replies", help: "Hold fn to talk. Oby replies aloud when this is on.") {
                Toggle("Speak replies", isOn: $speaks).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }
            IslandRow("Language") {
                Picker("Language", selection: $language) {
                    Text(VoiceSettings.systemName).tag("system")
                    ForEach(VoiceSettings.languages, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
        }
    }

    private var notifications: some View {
        IslandCard("Notifications") {
            IslandRow("Alerts", help: "Oby alerts you when a job needs you. An alert opens its job.") {
                if alerts == .notDetermined {
                    Button("Allow") { Task { await allow() } }
                } else if alerts == .denied {
                    Button("Open System Settings") {
                        if let url = Self.systemSettings { NSWorkspace.shared.open(url) }
                    }
                } else {
                    Text(NotificationsSection.text(alerts)).foregroundStyle(OBYStyle.secondary)
                }
            }
        }
        .task { await refresh() }
        // Back from the system's settings.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await refresh() } }
    }

    private static let systemSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")

    private func refresh() async {
        alerts = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func allow() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        await refresh()
    }
}

/// A titled group of rows on a card.
struct IslandCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: IslandSettings.Metrics.rowGap) {
            Text(title.uppercased()).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.5))
                .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(IslandSettings.Metrics.cardPadding)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// One control: its short label on the left, the control on the right, the same height as every row.
struct IslandRow<Control: View>: View {
    let label: String
    var help: String?
    @ViewBuilder let control: Control

    init(_ label: String, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
            Spacer(minLength: 12)
            control
        }
        .frame(minHeight: IslandSettings.Metrics.row)
        .help(help ?? "")
    }
}

/// The runner's default permission mode and its saved rules, as Settings › Permissions (Shared/PermissionsSection.swift)
/// without the paragraphs: the mode's line is its tooltip.
private struct IslandPermissions: View {
    var runner: Runner?
    var defaultMode: RunnerMode?
    var setDefault: (RunnerMode) async throws -> Void
    @State private var rules: [RunnerRule]?
    @State private var problem: String?

    var body: some View {
        IslandCard("Permissions") {
            if runner == nil {
                Text("No runner set").foregroundStyle(OBYStyle.secondary).frame(minHeight: IslandSettings.Metrics.row)
            } else if defaultMode == nil && rules == nil {
                Text("This runner doesn't ask first").foregroundStyle(OBYStyle.secondary).frame(minHeight: IslandSettings.Metrics.row)
            } else {
                IslandRow("Default mode", help: defaultMode?.help) {
                    Picker("Default mode", selection: Binding { defaultMode } set: { mode in
                        guard let mode else { return }
                        Task {
                            do { try await setDefault(mode); problem = nil } catch { problem = error.localizedDescription }
                        }
                    }) {
                        ForEach(RunnerMode.allCases) { Text($0.label).tag(RunnerMode?.some($0)) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                ForEach(rules ?? []) { rule in
                    IslandRow(rule.rule, help: [rule.decision == "deny" ? "Denied" : "Allowed", rule.repo].compactMap(\.self).joined(separator: " · ")) {
                        Button("Remove", role: .destructive) { remove(rule.id) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(rule.rule)")
                    }
                    .font(.system(size: 12, design: .monospaced))
                }
            }
            if let problem { Text(problem).font(OBYStyle.caption).foregroundStyle(.red) }
        }
        .task(id: runner?.base) { await load() }
    }

    private func load() async {
        guard let runner else { rules = nil; return }
        do {
            rules = try await runner.permissionRules()
            problem = nil
        } catch let error as RunnerError where error.status == 404 {
            // A runner without permissions.
            rules = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove(_ id: String) {
        guard let runner else { return }
        Task {
            do {
                try await runner.removeRule(id)
                rules?.removeAll { $0.id == id }
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
