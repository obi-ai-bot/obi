import SwiftUI

/// The runner Oby talks to, the accounts signed in there, each tool's model and effort, and the
/// Apple Watches that reach it without this iPhone.
struct SettingsScreen: View {
    @Environment(Phone.self) private var phone
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var options: ModelOptions?
    @State private var models: ModelSettings?
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
                    LabeledContent("Status", value: status)
                } header: {
                    Text("Runner")
                } footer: {
                    Text("The runner does the work while your Mac is closed. It answers only your Tailscale login, so this iPhone needs Tailscale on.")
                }

                Section("Accounts on the runner") {
                    if phone.accounts.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    } else {
                        Text(Usage.summary(phone.accounts.map(\.usage))).font(.subheadline)
                    }
                }
                ForEach(Usage.agents(phone.accounts.map(\.agent)), id: \.self) { agent in
                    Section(Usage.tool(agent)) {
                        ForEach(phone.accounts.filter { $0.agent == agent }) { account in
                            UsageCard(snapshot: account.usage)
                        }
                    }
                }

                if let options, let models {
                    Section("Claude Code") {
                        Picker("Model", selection: binding(\.claude.model)) {
                            ForEach(options.claude.models, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Picker("Effort", selection: binding(\.claude.effort)) {
                            ForEach(options.claude.efforts ?? [], id: \.self) { Text(effortName($0)).tag($0) }
                        }
                    }
                    Section("Codex") {
                        Picker("Model", selection: binding(\.codex.model)) {
                            ForEach(options.codex.models, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Picker("Effort", selection: binding(\.codex.effort)) {
                            ForEach(options.codex.models.first { $0.id == models.codex.model }?.efforts ?? [], id: \.self) {
                                Text(effortName($0)).tag($0)
                            }
                        }
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
                    Text("Oby opens a pull request by itself once a job's check passes and the secret scan is clean. Publishing by hand, when that failed, needs Face ID on this iPhone. Oby never merges.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task {
                address = phone.runnerURL.absoluteString
                models = phone.models
                do { options = try await phone.modelOptions() } catch { problem = error.localizedDescription }
                // A runner older than the Watch API has no list: then there's nothing to show.
                try? await watchPairing.load(phone)
            }
        }
    }

    private var status: String {
        switch phone.connection {
        case .live: "Connected to \(phone.host)"
        case .connecting: "Connecting…"
        case .offline(let why): why
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

    /// A picker binding that saves on the runner as soon as it changes.
    private func binding(_ path: WritableKeyPath<ModelSettings, String>) -> Binding<String> {
        Binding {
            models?[keyPath: path] ?? ""
        } set: { value in
            guard var changed = models else { return }
            changed[keyPath: path] = value
            models = changed
            Task {
                do { try await phone.setModels(changed) } catch { problem = error.localizedDescription }
            }
        }
    }

    private func effortName(_ effort: String) -> String { effort == "xhigh" ? "Extra high" : effort.capitalized }
}
