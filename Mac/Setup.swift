import AppKit
import ApplicationServices
import AVFoundation
import Observation
import UserNotifications

/// The permissions Oby uses, each asked only when it's needed and each on its own: one denied
/// leaves the others working.
@Observable
final class Permissions {
    enum Kind: CaseIterable { case accessibility, microphone, notifications }
    enum State { case allowed, notAsked, denied }

    private(set) var states: [Kind: State] = [:]

    func state(_ kind: Kind) -> State { states[kind] ?? .notAsked }

    func refresh() async {
        // macOS doesn't say whether Accessibility was refused, only whether it's allowed.
        states[.accessibility] = AXIsProcessTrusted() ? .allowed : .notAsked
        let microphone: State = switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        let notifications: State = switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: .allowed
        case .notDetermined: .notAsked
        default: .denied
        }
        states[.microphone] = microphone
        states[.notifications] = notifications
    }

    /// macOS's own prompt the first time; after that only System Settings can change it.
    func ask(_ kind: Kind) async {
        switch (kind, state(kind)) {
        case (_, .allowed):
            return
        case (.accessibility, _):
            // macOS's prompt the first time, System Settings after. The talk key's tap installs by
            // itself once it's allowed.
            if UserDefaults.standard.bool(forKey: "accessibilityAsked") {
                Self.openSettings(kind)
            } else {
                UserDefaults.standard.set(true, forKey: "accessibilityAsked")
                AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            }
        case (.microphone, .notAsked):
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case (.notifications, .notAsked):
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        default:
            Self.openSettings(kind)
        }
        await refresh()
    }

    static func title(_ kind: Kind) -> String {
        switch kind {
        case .accessibility: "Accessibility"
        case .microphone: "Microphone"
        case .notifications: "Notifications"
        }
    }

    /// Why Oby asks, in the words the step shows.
    static func reason(_ kind: Kind) -> String {
        switch kind {
        case .accessibility: "So Oby notices you holding fn (or Control-Option) in any app. It reads no other keys."
        case .microphone: "So Oby hears you while you hold fn, and only then. What you say is written down on this Mac."
        case .notifications: "So Oby tells you when a job on your runner is done or needs you, while the island is closed."
        }
    }

    /// Without it: what stops working, and nothing else.
    static func without(_ kind: Kind) -> String {
        switch kind {
        case .accessibility: "Without it, type to Oby in the island instead of holding fn."
        case .microphone: "Without it, type to Oby instead of talking."
        case .notifications: "Without it, check the island for your runner's jobs."
        }
    }

    static func symbol(_ kind: Kind) -> String {
        switch kind {
        case .accessibility: "keyboard"
        case .microphone: "mic"
        case .notifications: "bell.badge"
        }
    }

    static func openSettings(_ kind: Kind) {
        let pane = switch kind {
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        }
        if let url = URL(string: pane) { NSWorkspace.shared.open(url) }
    }
}

/// The coding tools on this Mac, which of them are connected, and the models each one offers.
/// Claude Code and Codex connect through Oby's accounts; Cursor through its own login (Oby can't
/// run jobs on it yet, F6); Gemini isn't in the first version.
@Observable
final class Tools {
    struct Model: Hashable { var id: String; var name: String }

    static let all = ["claude", "codex", "cursor", "gemini"]

    let store: AccountStore
    /// The command each installed tool runs as, by agent.
    private(set) var installed: [String: String] = [:]
    /// Each connected tool's own model list, by agent.
    private(set) var models: [String: [Model]] = [:]
    private(set) var looking = false

    init(store: AccountStore) { self.store = store }

    /// Signed in, with a model list Oby could read.
    var connected: [String] { Self.all.filter { !(models[$0] ?? []).isEmpty } }

    func accounts(_ agent: String) -> [AccountState] { store.accounts.filter { $0.account.agent == agent } }

    func refresh() async {
        looking = true
        defer { looking = false }
        var found: [String: String] = [:]
        for (agent, commands) in [("claude", ["claude"]), ("codex", ["codex"]), ("cursor", ["cursor-agent"]), ("gemini", ["gemini"])] {
            for command in commands {
                if await Self.onPath(command) {
                    found[agent] = command
                    break
                }
            }
        }
        installed = found
        await store.refresh()

        var lists: [String: [Model]] = [:]
        if found["claude"] != nil, accounts("claude").contains(where: \.signedIn) {
            // Claude Code has no command that lists models: Oby's own list of Claude Code's models.
            lists["claude"] = AgentModels.claude.map { Model(id: $0.0, name: $0.1) }
        }
        if found["codex"] != nil, let account = accounts("codex").first(where: \.signedIn) {
            let home = account.account.home.map { URL(filePath: $0) }
            lists["codex"] = ((try? await CodexAgent.models(home: home)) ?? []).map { Model(id: $0.id, name: $0.name) }
        }
        if let cursor = found["cursor"], let out = try? await Shell.run([cursor, "models"], timeout: 30), out.status == 0 {
            lists["cursor"] = Self.cursorModels(out.text)
        }
        models = lists
    }

    /// Codex gets an account of its own, then signs in to it in Terminal.
    func connect(_ agent: String) throws {
        if let account = accounts(agent).first(where: { !$0.signedIn })?.account {
            try store.signIn(account)
        } else {
            try store.signIn(store.add(agent: agent, name: "Personal", payer: ""))
        }
    }

    /// Opens Terminal on Cursor's own login.
    func signInCursor() throws {
        guard let command = installed["cursor"] else { return }
        let script = FileManager.default.temporaryDirectory.appending(path: "oby-sign-in-cursor.command")
        try "#!/bin/sh\necho 'Oby: sign in to Cursor.'\n\(command) login\necho\necho 'Done? Go back to Oby. You can close this window.'\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        guard NSWorkspace.shared.open(script) else { throw Shell.Failure(message: "Couldn't open Terminal to sign in.") }
    }

    nonisolated static func onPath(_ command: String) async -> Bool {
        (try? await Shell.run(["which", command], timeout: 10))?.status == 0
    }

    /// `cursor-agent models` prints one model a line, as "id - Name", maybe marked "(current)" or
    /// "(default)", between a heading and tips.
    nonisolated static func cursorModels(_ text: String) -> [Model] {
        let plain = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return plain.split(separator: "\n").compactMap { line in
            let parts = line.components(separatedBy: " - ")
            guard parts.count >= 2 else { return nil }
            let id = parts[0].trimmingCharacters(in: .whitespaces)
            guard !id.isEmpty, !id.contains(" "), !id.hasSuffix(":") else { return nil }
            let name = parts.dropFirst().joined(separator: " - ")
                .replacingOccurrences(of: #"\s*\((current|default)\)"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            return Model(id: id, name: name.isEmpty ? id : name)
        }
    }
}

/// Which model does what: the Lead thinks, routine jobs run on a smaller model, complex jobs on a
/// stronger one. Routine jobs are each tool's `<agent>.model`, which jobs already read; the
/// Lead's pick waits for the Lead (#64); the complex pick is what the island offers for complex work.
enum ModelPicks {
    /// The best planner first: Claude holds Oby to a typed plan, then Codex, then Cursor.
    static let planners = ["claude", "codex", "cursor"]
    /// The tools Oby can run jobs on today: Cursor's runner is F6.
    static let workers = ["claude", "codex"]

    /// 0 small, 1 everyday, 2 strong, 3 strongest (Fable, Astra: only when the user picks it).
    nonisolated static func size(_ id: String) -> Int {
        // "gemini" holds "mini": it says nothing about size.
        let id = id.lowercased().replacingOccurrences(of: "gemini", with: "")
        if ["fable", "astra"].contains(where: { id.contains($0) }) { return 3 }
        if ["opus", "-max", "-pro", "ultra"].contains(where: { id.contains($0) }) { return 2 }
        if ["haiku", "mini", "nano", "flash", "lite", "small"].contains(where: { id.contains($0) }) { return 0 }
        return 1
    }

    /// A model smaller than the complex jobs': an everyday one (Sonnet 5.5 for Claude Code) when
    /// there's a strong one above it. When there isn't (Codex, whose stronger Astra needs asking),
    /// complex jobs take the first everyday model, so routine jobs go one smaller: a small model,
    /// else a later everyday one (lists put the newest first). Cursor's "auto" only if it's all
    /// there is: that's Cursor choosing, not a model.
    nonisolated static func routine(_ models: [String]) -> String? {
        let models = models == ["auto"] ? models : models.filter { $0 != "auto" }
        let everyday = models.filter { size($0) == 1 }
        if !models.contains(where: { size($0) == 2 }) {
            if let small = models.first(where: { size($0) == 0 }) { return small }
            if everyday.count > 1 { return everyday.last }
        }
        return everyday.first ?? models.min { size($0) < size($1) }
    }

    /// The strongest model short of the ones that need asking (Opus 5.5 for Claude Code).
    nonisolated static func complex(_ models: [String]) -> String? {
        let allowed = models.filter { size($0) < 3 }
        return (allowed.isEmpty ? models : allowed).max { size($0) < size($1) }
    }

    /// The Lead thinks with the best planner connected, on its routine model.
    nonisolated static func lead(_ models: [String: [String]]) -> (agent: String, model: String)? {
        for agent in planners {
            if let model = routine(models[agent] ?? []) { return (agent, model) }
        }
        return nil
    }

    /// A value the user saved (in first launch or Settings), not one of Oby's registered defaults.
    static func saved(_ key: String) -> String? {
        UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[key] as? String
    }

    /// The model the island offers for complex work: the user's pick, else Oby's stronger model
    /// (for whoever never picked). Nil when that's the model jobs already use: nothing to offer.
    static func complex(for agent: String) -> String? {
        let model = UserDefaults.standard.string(forKey: "\(agent).complexModel") ?? AgentModels.stronger[agent]
        return model == AgentModels.value(agent, "model") ? nil : model
    }
}
