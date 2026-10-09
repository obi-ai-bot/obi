import SwiftUI

/// The runner Oby talks to, the accounts signed in there, and each tool's model and effort.
struct SettingsScreen: View {
    @Environment(Phone.self) private var phone
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var options: ModelOptions?
    @State private var models: ModelSettings?
    @State private var problem: String?

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
                    if phone.accounts.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                    ForEach(phone.accounts) { account in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.title)
                            Text(account.label ?? "Signed out").font(.caption).foregroundStyle(.secondary)
                            if account.signedIn {
                                Text("5h \(percent(account.fiveHour)) · 7d \(percent(account.sevenDay)) · \(account.running) running")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
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
                    LabeledContent("Publishing key", value: DeviceKey.isAvailable ? (phone.deviceID == nil ? "Not registered yet" : "Registered, Face ID") : "Needs a real iPhone")
                    if let problem { Text(problem).foregroundStyle(.red) }
                } footer: {
                    Text("Nothing is published without Face ID on this iPhone. Oby never merges.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task {
                address = phone.runnerURL.absoluteString
                models = phone.models
                do { options = try await phone.modelOptions() } catch { problem = error.localizedDescription }
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

    private func percent(_ used: Double?) -> String {
        used.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"
    }

    private func effortName(_ effort: String) -> String { effort == "xhigh" ? "Extra high" : effort.capitalized }
}
