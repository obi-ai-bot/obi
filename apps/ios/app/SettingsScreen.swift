import SwiftUI

/// Settings, opened over Home from your picture: the runner Oby talks to, the accounts signed in there, each tool's model and
/// effort, and the Apple Watches that reach it without this iPhone. The sections the Mac has too
/// are shared (apps/shared/SettingsSections.swift).
struct SettingsScreen: View {
    @Environment(Phone.self) private var phone
    @State private var address = ""
    @State private var options: ModelOptions?
    @State private var problem: String?
    @State private var watchPairing = WatchPairing()
    @State private var watchProblem: String?
    @State private var stopping = false
    @AppStorage(Appearance.key) private var appearance = Appearance.system

    var body: some View {
            Form {
                Group {
                Section {
                    TextField("https://…", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveAddress)
                    LabeledContent("Status", value: phone.connection == .live ? phone.connection.status(host: phone.host) : phone.offlineLine)
                } header: {
                    Text("Runner")
                } footer: {
                    Text("The runner does the work while your Mac is closed. It answers only your Tailscale login, so this iPhone needs Tailscale on.")
                }

                Section {
                    NavigationLink {
                        ConnectScreen()
                    } label: {
                        LabeledContent("Your Mac", value: phone.link.map { phone.route?.label ?? $0.name } ?? "Not linked")
                    }
                } footer: {
                    Text("Reach your Mac from anywhere: at home over the local network, away through the Mac's own tunnel (its Settings › Remote access).")
                }

                VoiceSection(speaks: Binding(get: { phone.speakReplies }, set: { phone.speakReplies = $0 }))

                NotificationsSection { UIApplication.shared.registerForRemoteNotifications() }

                AccountSections("Accounts on the runner", items: phone.accounts, id: \.id, usage: \.usage) { account in
                    UsageCard(snapshot: account.usage)
                    // The runner's "accounts" event brings the change back.
                    ReserveSwitch(snapshot: account.usage) { lift in _ = try await phone.runner.liftReserve(account.id, lift) }
                    if account.signedIn {
                        Text(Usage.tetrix(account.tetrix, jobs: account.tetrixJobs ?? 0, used: account.tetrixUsed ?? 0))
                            .font(.footnote).foregroundStyle(account.tetrix == false ? Color.orange : Color.secondary)
                    }
                }

                PermissionsSection(runner: phone.runner, defaultMode: phone.defaultMode, setDefault: phone.setDefaultMode)

                RunnerModelsSections(options: options, models: phone.models, save: phone.setModels)

                if !phone.active.isEmpty {
                    Section {
                        // Off Home (Sangam's has none), and never without asking (docs/oby-ux.md row 20).
                        Button("Stop every task", role: .destructive) { stopping = true }
                            .foregroundStyle(Tokens.danger)
                            .confirmationDialog("Stop \(phone.active.count == 1 ? "the running task" : "all \(phone.active.count) running tasks")?",
                                                isPresented: $stopping, titleVisibility: .visible) {
                                Button("Stop every task", role: .destructive) {
                                    Task { do { try await phone.stopAll(); problem = nil } catch { problem = error.localizedDescription } }
                                }
                            } message: {
                                Text("Each ends where it is. What they changed stays on their branches.")
                            }
                    } footer: {
                        Text("Stops every task on your Mac, as ⌃⌥⌘. does there.")
                    }
                }

                Section {
                    TextField("Client ID", text: $watchPairing.clientID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Client secret", text: $watchPairing.clientSecret)
                    Button(watchPairing.busy ? "Pairing…" : "Pair Apple Watch") {
                        Task {
                            watchProblem = nil
                            do { try await watchPairing.pair(phone) } catch { watchProblem = error.localizedDescription }
                        }
                    }
                    .disabled(!watchPairing.canPair)
                    ForEach(watchPairing.watches) { watch in
                        LabeledContent(watch.name, value: "Paired")
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { watchPairing.watches[$0].id }
                        Task {
                            for id in ids {
                                do { try await watchPairing.remove(id, phone) } catch { watchProblem = error.localizedDescription }
                            }
                        }
                    }
                    if let watchProblem { Text(watchProblem).foregroundStyle(.red) }
                } header: {
                    Text("Apple Watch without iPhone")
                } footer: {
                    Text("Away from this iPhone, your watch reaches the runner through your Cloudflare Tunnel. Paste the Cloudflare Access service token; pairing asks for Face ID, with Oby open on the watch. Swipe a watch to remove it.")
                }

                Section {
                    LabeledContent("Publishing key", value: DeviceKey.isAvailable ? (phone.deviceID == nil ? "Not registered yet" : "Registered, Face ID") : "Needs a real iPhone")
                    if let problem { Text(problem).foregroundStyle(.red) }
                } footer: {
                    Text("Oby opens a pull request by itself once a job's check passes and the secret scan is clean. Publishing by hand, when that failed, needs Face ID on this iPhone. Oby merges only into dev, once its review approves and your Mac's checks pass.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                Section("About") {
                    LabeledContent("Version", value: Self.version)
                    LabeledContent("Runner", value: phone.host.isEmpty ? "Not reached yet" : phone.host)
                }
                }
                // Sangam's settings cards: the surface colour, rows at least 56 tall.
                .listRowBackground(Tokens.surface)
            }
            .environment(\.defaultMinListRowHeight, 56)
            .obyPage()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                address = phone.runnerURL.absoluteString
                do { options = try await phone.runner.modelOptions() } catch { problem = error.localizedDescription }
                // A runner older than the Watch API has no list: then there's nothing to show.
                try? await watchPairing.load(phone)
            }
    }

    /// "0.9 (42)", as the bundle says it.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        return info?["CFBundleVersion"].map { "\(short) (\($0))" } ?? short
    }

    private func saveAddress() {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)), url.scheme == "https" else {
            problem = "The runner's address starts with https://"
            return
        }
        problem = nil
        if url != phone.runnerURL { phone.runnerURL = url }
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
