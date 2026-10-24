import SwiftUI

/// Settings, opened over Home from your picture (Sangam's SettingsView.tsx): a 28/600 title over his
/// cards (apps/shared/SettingsComponents.swift), in docs/oby-ux.md row 39's order: Your Mac,
/// Accounts, Models, Permissions, Notifications, Voice, Appearance, About; then what only the iPhone
/// has. The sections the Mac has too are shared (apps/shared/SettingsSections.swift) and draw as
/// cards here, as on the Mac.
struct SettingsScreen: View {
    @Environment(Phone.self) private var phone
    @State private var options: ModelOptions?
    @State private var problem: String?
    @State private var watchPairing = WatchPairing()
    @State private var watchProblem: String?
    @State private var stopping = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system
    /// The launch build (`Launch`) hides Connectors (Tetrix) and Apple Watch without iPhone.
    @AppStorage(Launch.everythingKey) private var everything = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(Tokens.font(28, .semibold)).foregroundStyle(Tokens.ink)
                    .padding(.bottom, 16).accessibilityAddTraits(.isHeader)
                yourMac
                AccountSections("Accounts", items: phone.accounts, id: \.id, usage: \.usage,
                                footer: "Each tool signs in on your Mac, with its own login.") { account in
                    // The runner's "accounts" event brings a lifted reserve back.
                    PhoneAccountRow(account: account) { lift in _ = try await phone.runner.liftReserve(account.id, lift) }
                }
                if everything { connectors }
                RunnerModelsSections(options: options, models: phone.models, save: phone.setModels)
                PermissionsSection(runner: phone.runner, defaultMode: phone.defaultMode, setDefault: phone.setDefaultMode)
                RoutinesSection(runner: phone.runner, changes: phone.routineChanges)
                NotificationsSection { UIApplication.shared.registerForRemoteNotifications() }
                VoiceSection()
                SetGroup("Appearance") {
                    SetRow("Appearance") {
                        SetSegmented("Appearance", selection: $appearance, options: Appearance.allCases.map { ($0, $0.label) })
                    }
                }
                if !phone.active.isEmpty { stopEverything }
                SetGroup("About") {
                    SetRow("Version") { SetValue(Self.version) }
                    SetRow("Mac") { SetValue(phone.host.isEmpty ? "Not reached yet" : phone.host) }
                }
                if everything { watch }
                SetGroup("Publishing key", footer: "Oby opens a pull request by itself once a job's check passes and the secret scan is clean. Publishing by hand, when that failed, needs Face ID on this iPhone.",
                         problem: problem) {
                    SetRow("This iPhone's key") {
                        SetValue(DeviceKey.isAvailable ? (phone.deviceID == nil ? "Not registered yet" : "Registered, Face ID") : "Needs a real iPhone")
                    }
                }
            }
            .padding(.horizontal, Tokens.gutter).padding(.top, 8).padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .environment(\.settingsCards, true)
        .obyPage()
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do { options = try await phone.runner.modelOptions() } catch { problem = error.localizedDescription }
            // A runner older than the Watch API has no list: then there's nothing to show.
            if everything { try? await watchPairing.load(phone) }
        }
    }

    /// Sangam's Connectors, as far as the iPhone goes: Tetrix, which obid on the Mac holds once for
    /// every agent. The iPhone can't start it: Tetrix's sign-in and its login stay on the Mac, so the
    /// row says where to go. Connected once the Mac's accounts say their agents have it.
    private var connectors: some View {
        let connected = phone.accounts.contains { $0.tetrix == true }
        return SetGroup("Connectors", footer: connected ? nil : "Connect Tetrix on your Mac, in Settings › Connectors: one sign-in, for every agent. Its login stays there, never on this iPhone.") {
            SetRow("Tetrix", about: TetrixStatus.about) {
                SetValue(connected ? "Connected" : "Connect on your Mac", connected: connected)
            }
        }
    }

    /// Your Mac (docs/ios-design.md "Settings"): its name, how it's reached, a green dot while
    /// connected; a tap opens pairing.
    private var yourMac: some View {
        SetGroup("Your Mac") {
            NavigationLink { ConnectScreen() } label: {
                SetRow(phone.link?.name ?? "No Mac paired yet", about: phone.link == nil ? "Pair this iPhone with Oby on your Mac." : phone.route?.label) {
                    HStack(spacing: 8) {
                        if phone.link != nil {
                            SetValue(phone.notice?.title ?? (phone.connection == .live ? "Connected" : "Connecting…"), connected: phone.connection == .live)
                        }
                        Image(systemName: "chevron.right").font(Tokens.font(12, .semibold)).foregroundStyle(Tokens.muted)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// Off Home (Sangam's has none), and never without asking (docs/oby-ux.md row 20).
    private var stopEverything: some View {
        SetGroup(footer: "Stops every task on your Mac, as ⌃⌥⌘. does there.") {
            SetRow("Stop every task", about: "\(phone.active.count) running") {
                Button("Stop", role: .destructive) { stopping = true }.buttonStyle(.set)
            }
        }
        .confirmationDialog("Stop \(phone.active.count == 1 ? "the running task" : "all \(phone.active.count) running tasks")?",
                            isPresented: $stopping, titleVisibility: .visible) {
            Button("Stop every task", role: .destructive) {
                Task { do { try await phone.stopAll(); problem = nil } catch { problem = error.localizedDescription } }
            }
        } message: {
            Text("Each ends where it is. What they changed stays on their branches.")
        }
    }

    /// Apple Watches that reach the runner without this iPhone.
    private var watch: some View {
        SetGroup("Apple Watch without iPhone",
                 footer: "Away from this iPhone, your watch reaches the runner through your Cloudflare Tunnel. Paste the Cloudflare Access service token; pairing asks for Face ID, with Oby open on the watch.",
                 problem: watchProblem) {
            SetRow("Client ID") { SetField("Client ID", text: $watchPairing.clientID, prompt: "…access", width: 180).textInputAutocapitalization(.never) }
            SetRow("Client secret") { SetField("Client secret", text: $watchPairing.clientSecret, prompt: "Secret", secret: true, width: 180) }
            SetRow(watchPairing.watches.isEmpty ? "No watch paired" : "Pair another watch") {
                Button(watchPairing.busy ? "Pairing…" : "Pair") {
                    Task {
                        watchProblem = nil
                        do { try await watchPairing.pair(phone) } catch { watchProblem = error.localizedDescription }
                    }
                }
                .buttonStyle(.set)
                .disabled(!watchPairing.canPair)
            }
            ForEach(watchPairing.watches) { watch in
                SetRow(watch.name, about: "Paired") {
                    Button("Remove", role: .destructive) {
                        Task { do { try await watchPairing.remove(watch.id, phone) } catch { watchProblem = error.localizedDescription } }
                    }
                    .buttonStyle(.set)
                }
            }
        }
    }

    /// "0.9 (42)", as the bundle says it.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return info?["CFBundleVersion"].map { "\(short) (\($0))" } ?? short
    }


}

/// Settings › Appearance (docs/oby-ux.md row 1): the system's light or dark, or one of them always.
enum Appearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"
    var label: String { rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// One account on the Mac (the Mac's AccountUsageRow, on the iPhone): its name, plan and when its
/// week resets, the week's bar, the 5-hour window past 80%, its reserve, and Tetrix. Signing in
/// happens on the Mac, where the tools run.
private struct PhoneAccountRow: View {
    let account: Account
    var lift: @MainActor (Bool) async throws -> Void
    @State private var problem: String?
    @AppStorage(Launch.everythingKey) private var everything = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let usage = account.usage, now = context.date
            SetRow {
                HStack(alignment: .top, spacing: 16) {
                    AgentMark(agent: account.agent).font(Tokens.font(13)).foregroundStyle(Tokens.muted)
                        .frame(width: 16).padding(.top, 2).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.name)
                        SetAbout(account.signedIn ? Usage.about(usage, payer: "", now: now) : "Signed out: sign in on your Mac")
                        if let week = Usage.week(usage, now: now) { SetMeter(used: week * 100).padding(.top, 4) }
                        if let line = Usage.fiveHourLine(usage, now: now) {
                            SetAbout(line, color: SetMeter.fill(used: (usage.fiveHour ?? 0) * 100))
                        }
                        if usage.reserved(at: now) { SetAbout(Usage.reservedText, color: Tokens.needsInk) }
                        if usage.signedIn, usage.inReserve(at: now) {
                            HStack {
                                Text(Usage.liftText)
                                Spacer(minLength: 12)
                                Toggle(Usage.liftText, isOn: Binding(get: { usage.liftedUntil(at: now) != nil }, set: { on in
                                    Task { do { try await lift(on); problem = nil } catch { problem = error.localizedDescription } }
                                }))
                                .toggleStyle(.set)
                            }
                            .padding(.top, 6)
                            SetAbout(Usage.liftNote(usage))
                            if let problem { SetAbout(problem, color: Tokens.danger) }
                        }
                        if everything, account.signedIn {
                            SetAbout(TetrixJobReport.accountLine(connected: account.tetrix == true, jobs: account.tetrixJobs ?? 0,
                                                                 used: account.tetrixUsed ?? 0, there: "on your Mac"),
                                     color: account.tetrix == true ? Tokens.muted : Tokens.needsInk)
                        }
                    }
                }
            }
        }
    }
}
