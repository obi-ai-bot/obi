#if os(iOS) || os(macOS)
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// Settings' sections the iPhone and the Mac both show, so the two stay alike: apps/ios/app/SettingsScreen.swift
// puts them in its form, apps/mac/app/Settings.swift on its pages as Sangam's cards (`settingsCards`,
// apps/shared/SettingsComponents.swift), next to what only that device has.

/// Voice: the language Oby writes down what you say in (`VoiceSettings`). Oby answers in writing,
/// never aloud (the owner's decision of 2026-10-23).
struct VoiceSection: View {
    /// What only this device says about it, like the Mac's talk key.
    var footer: String? = nil
    @AppStorage(VoiceSettings.language) private var language = "system"
    @Environment(\.settingsCards) private var cards

    var body: some View {
        if cards {
            SetGroup("Voice", footer: footer) {
                SetRow("Speech language") {
                    SetSelect("Speech language", selection: $language,
                              options: [("system", VoiceSettings.systemName)] + VoiceSettings.languages.map { ($0.id, $0.name) })
                }
            }
        } else {
            form
        }
    }

    private var form: some View {
        Section {
            Picker("Speech language", selection: $language) {
                Text(VoiceSettings.systemName).tag("system")
                ForEach(VoiceSettings.languages, id: \.id) { Text($0.name).tag($0.id) }
            }
        } header: {
            Text("Voice")
        } footer: {
            if let footer { Text(footer) }
        }
    }
}

/// Accounts and their usage: a line on the one with the most room, then each tool's accounts, each
/// with its usage card (apps/shared/Usage.swift) or the row the device gives it. As cards (the Mac),
/// the line is Sangam's "Most room: …" and each row is the device's own `SetRow`.
struct AccountSections<Item, ID: Hashable, Row: View>: View {
    var title: String
    var items: [Item]
    var id: KeyPath<Item, ID>
    var usage: (Item) -> Usage.Snapshot
    /// After each tool's name, like "on tetrix-lab", when a form lists accounts from two places.
    var place: String?
    /// Under the line, as cards.
    var footer: String?
    var row: (Item) -> Row

    init(_ title: String, items: [Item], id: KeyPath<Item, ID>, usage: @escaping (Item) -> Usage.Snapshot,
         place: String? = nil, footer: String? = nil, @ViewBuilder row: @escaping (Item) -> Row) {
        self.title = title
        self.items = items
        self.id = id
        self.usage = usage
        self.place = place
        self.footer = footer
        self.row = row
    }

    @Environment(\.settingsCards) private var cards

    var body: some View {
        if cards {
            SetGroup(title, footer: footer) {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    SetRow(Usage.mostRoom(items.map(usage), now: context.date), quiet: items.isEmpty)
                }
            }
            ForEach(Usage.agents(items.map { usage($0).agent }), id: \.self) { agent in
                SetGroup(place.map { "\(Usage.tool(agent)) \($0)" } ?? Usage.tool(agent)) {
                    ForEach(items.filter { usage($0).agent == agent }, id: id, content: row)
                }
            }
        } else {
            form
        }
    }

    @ViewBuilder private var form: some View {
        Section(title) {
            if items.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            } else {
                Text(Usage.summary(items.map(usage))).font(.subheadline)
            }
        }
        ForEach(Usage.agents(items.map { usage($0).agent }), id: \.self) { agent in
            Section(place.map { "\(Usage.tool(agent)) \($0)" } ?? Usage.tool(agent)) {
                ForEach(items.filter { usage($0).agent == agent }, id: id, content: row)
            }
        }
    }
}

extension AccountSections where Row == UsageCard {
    /// Each account as its usage card alone.
    init(_ title: String, items: [Item], id: KeyPath<Item, ID>, usage: @escaping (Item) -> Usage.Snapshot, place: String? = nil) {
        self.init(title, items: items, id: id, usage: usage, place: place) { UsageCard(snapshot: usage($0)) }
    }
}

/// The model and effort the runner's Claude Code and Codex jobs use, from what the runner offers
/// (the form loads them: `Runner.modelOptions`), saved there as soon as a picker changes.
struct RunnerModelsSections: View {
    var options: ModelOptions?
    /// What the runner last said it uses, or nil before it has.
    var models: ModelSettings?
    var save: (ModelSettings) async throws -> Void
    /// After each tool's name, like "on tetrix-lab", when the form has this device's models too.
    var place: String? = nil
    /// Under the last group, as cards.
    var footer: String? = nil
    /// The pickers' choice since the form opened.
    @State private var chosen: ModelSettings?
    @State private var problem: String?
    @Environment(\.settingsCards) private var cards

    var body: some View {
        if let options, let current = chosen ?? models {
            if cards { groups(options, current) } else { sections(options, current) }
        }
    }

    @ViewBuilder private func groups(_ options: ModelOptions, _ current: ModelSettings) -> some View {
        let claudeEfforts = options.claude.efforts ?? []
        let claudeComplex = options.claude.complexEfforts ?? claudeEfforts
        let codexEfforts = options.codex.models.first { $0.id == current.codex.model }?.efforts ?? []
        SetGroup(title("Claude Code")) {
            SetRow("Model") { SetSelect("Claude Code model", selection: binding(\.claude.model), options: options.claude.models.map { ($0.id, $0.name) }) }
            SetRow("Effort") { SetSelect("Claude Code effort", selection: binding(\.claude.effort), options: claudeEfforts.map { ($0, ModelChoice.effortName($0)) }) }
            SetRow("Complex job effort") {
                SetSelect("Claude Code complex job effort", selection: complexBinding(\.claude, choices: claudeComplex), options: claudeComplex.map { ($0, ModelChoice.effortName($0)) })
            }
        }
        let cursor = options.cursor.map { [("auto", "Auto")] + $0.models.filter { $0.id != "auto" }.map { ($0.id, $0.name) } }
        SetGroup(title("Codex"), footer: cursor == nil ? footer : nil, problem: cursor == nil ? problem : nil) {
            SetRow("Model") { SetSelect("Codex model", selection: binding(\.codex.model), options: options.codex.models.map { ($0.id, $0.name) }) }
            SetRow("Effort") { SetSelect("Codex effort", selection: binding(\.codex.effort), options: codexEfforts.map { ($0, ModelChoice.effortName($0)) }) }
            SetRow("Complex job effort") {
                SetSelect("Codex complex job effort", selection: complexBinding(\.codex, choices: codexEfforts), options: codexEfforts.map { ($0, ModelChoice.effortName($0)) })
            }
        }
        // Cursor has a model and no effort; an older runner offers none.
        if let cursor {
            SetGroup(title("Cursor"), footer: footer, problem: problem) {
                SetRow("Model") { SetSelect("Cursor model", selection: cursorBinding, options: cursor) }
            }
        }
    }

    /// Cursor's model on the runner, Auto while it has none.
    private var cursorBinding: Binding<String> {
        Binding {
            (chosen ?? models)?.cursor?.model ?? "auto"
        } set: { value in
            guard var changed = chosen ?? models else { return }
            changed.cursor = CursorModelChoice(model: value)
            chosen = changed
            Task {
                do { try await save(changed); problem = nil }
                catch { problem = error.localizedDescription }
            }
        }
    }

    @ViewBuilder private func sections(_ options: ModelOptions, _ current: ModelSettings) -> some View {
        Section(title("Claude Code")) {
            Picker("Model", selection: binding(\.claude.model)) {
                ForEach(options.claude.models, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Effort", selection: binding(\.claude.effort)) {
                ForEach(options.claude.efforts ?? [], id: \.self) { Text(ModelChoice.effortName($0)).tag($0) }
            }
            Picker("Complex job effort", selection: complexBinding(\.claude, choices: options.claude.complexEfforts ?? options.claude.efforts ?? [])) {
                ForEach(options.claude.complexEfforts ?? options.claude.efforts ?? [], id: \.self) { Text(ModelChoice.effortName($0)).tag($0) }
            }
        }
        Section(title("Codex")) {
            Picker("Model", selection: binding(\.codex.model)) {
                ForEach(options.codex.models, id: \.id) { Text($0.name).tag($0.id) }
            }
            Picker("Effort", selection: binding(\.codex.effort)) {
                ForEach(options.codex.models.first { $0.id == current.codex.model }?.efforts ?? [], id: \.self) {
                    Text(ModelChoice.effortName($0)).tag($0)
                }
            }
            Picker("Complex job effort", selection: complexBinding(\.codex, choices: options.codex.models.first { $0.id == current.codex.model }?.efforts ?? [])) {
                ForEach(options.codex.models.first { $0.id == current.codex.model }?.efforts ?? [], id: \.self) { Text(ModelChoice.effortName($0)).tag($0) }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        }
    }

    private func title(_ tool: String) -> String { place.map { "\(tool) \($0)" } ?? tool }

    /// A picker binding that saves on the runner as soon as it changes.
    private func binding(_ path: WritableKeyPath<ModelSettings, String>) -> Binding<String> {
        Binding {
            (chosen ?? models)?[keyPath: path] ?? ""
        } set: { value in
            guard var changed = chosen ?? models else { return }
            changed[keyPath: path] = value
            chosen = changed
            Task {
                do {
                    try await save(changed)
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }

    private func complexBinding(_ path: WritableKeyPath<ModelSettings, ModelChoice>, choices: [String]) -> Binding<String> {
        Binding {
            let choice = (chosen ?? models)?[keyPath: path]
            return choice?.complexEffort ?? choice?.effort ?? choices.first ?? ""
        } set: { value in
            guard var changed = chosen ?? models else { return }
            changed[keyPath: path].complexEffort = value
            chosen = changed
            Task {
                do { try await save(changed); problem = nil }
                catch { problem = error.localizedDescription }
            }
        }
    }
}

/// Notifications: whether Oby may alert you when a job needs you, a way to allow it, and the way to
/// the system's settings once it was turned off.
struct NotificationsSection: View {
    /// Runs once the user allows alerts, like the iPhone's push registration.
    var allowed: () -> Void = {}
    @State private var status: UNAuthorizationStatus?
    @State private var problem: String?
    @Environment(\.openURL) private var openURL
    @Environment(\.settingsCards) private var cards

    private static let footer = "Oby alerts you when a job needs you: ready to publish, failed or interrupted, a question for you, out of reviews or not merged. An alert opens its job."

    var body: some View {
        if cards {
            SetGroup("Notifications", footer: Self.footer, problem: problem) {
                SetRow("Alerts") {
                    SetValue(Self.text(status))
                    if status == .notDetermined {
                        Button("Allow Alerts") { Task { await ask() } }.buttonStyle(.set)
                    } else if status == .denied, let url = Self.settings {
                        Button(Self.settingsName) { openURL(url) }.buttonStyle(.set)
                    }
                }
                .task { await refresh() }
                .onReceive(NotificationCenter.default.publisher(for: Self.becameActive)) { _ in Task { await refresh() } }
            }
        } else {
            form
        }
    }

    private var form: some View {
        Section {
            LabeledContent("Alerts", value: Self.text(status))
                // On the row, not the section: a section's modifiers go to each of its rows.
                .task { await refresh() }
                // Back from the system's settings.
                .onReceive(NotificationCenter.default.publisher(for: Self.becameActive)) { _ in Task { await refresh() } }
            if status == .notDetermined {
                Button("Allow Alerts") { Task { await ask() } }
            } else if status == .denied, let url = Self.settings {
                Button(Self.settingsName) { openURL(url) }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        } header: {
            Text("Notifications")
        } footer: {
            Text(Self.footer)
        }
    }

    private func refresh() async {
        status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    private func ask() async {
        do {
            if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { allowed() }
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        await refresh()
    }

    static func text(_ status: UNAuthorizationStatus?) -> String {
        switch status {
        case .authorized: "Allowed"
        #if os(iOS)
        case .ephemeral: "Allowed"
        #endif
        case .provisional: "Delivered quietly"
        case .denied: "Off"
        case .notDetermined: "Not asked yet"
        default: "…"
        }
    }

    #if os(iOS)
    private static let settings = URL(string: UIApplication.openNotificationSettingsURLString)
    private static let settingsName = "Open Settings"
    private static let becameActive = UIApplication.didBecomeActiveNotification
    #else
    private static let settings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    private static let settingsName = "Open System Settings"
    private static let becameActive = NSApplication.didBecomeActiveNotification
    #endif
}
#endif
