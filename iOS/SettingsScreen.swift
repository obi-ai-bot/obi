import SwiftUI

/// The runner Oby talks to, the accounts signed in there, each tool's model and effort, and the
/// Apple Watches that reach it without this iPhone. The sections the Mac has too are shared
/// (Shared/SettingsSections.swift).
struct SettingsScreen: View {
    @Environment(Phone.self) private var phone
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var options: ModelOptions?
    @State private var problem: String?
    @State private var watchPairing = WatchPairing()
    @State private var watchProblem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://…", text: $address)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(saveAddress)
                    LabeledContent("Status", value: phone.connection.status(host: phone.host))
                } header: {
                    Text("Runner")
                } footer: {
                    Text("The runner does the work while your Mac is closed. It answers only your Tailscale login, so this iPhone needs Tailscale on.")
                }

                VoiceSection(speaks: Binding(get: { phone.speakReplies }, set: { phone.speakReplies = $0 }))

                NotificationsSection { UIApplication.shared.registerForRemoteNotifications() }

                AccountSections("Accounts on the runner", items: phone.accounts, id: \.id, usage: \.usage) { account in
                    UsageCard(snapshot: account.usage)
                    if account.signedIn {
                        Text(Usage.tetrix(account.tetrix, jobs: account.tetrixJobs ?? 0, used: account.tetrixUsed ?? 0))
                            .font(.footnote).foregroundStyle(account.tetrix == false ? Color.orange : Color.secondary)
                    }
                }

                PermissionsSection(runner: phone.runner, defaultMode: phone.defaultMode, setDefault: phone.setDefaultMode)

                RunnerModelsSections(options: options, models: phone.models, save: phone.setModels)

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
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task {
                address = phone.runnerURL.absoluteString
                do { options = try await phone.runner.modelOptions() } catch { problem = error.localizedDescription }
                // A runner older than the Watch API has no list: then there's nothing to show.
                try? await watchPairing.load(phone)
            }
        }
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
