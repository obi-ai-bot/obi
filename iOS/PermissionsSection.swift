import SwiftUI

/// Settings › Permissions: the mode jobs on the runner get when a dispatch doesn't pick one, and
/// the rules Always allow (or Deny) saved there, each removed with a swipe or its button.
struct PermissionsSection: View {
    @Environment(Phone.self) private var phone
    /// Nil until the runner answered, or when it has no rules to list (older runners).
    @State private var rules: [RunnerRule]?
    @State private var problem: String?

    var body: some View {
        Section {
            if phone.defaultMode == nil && rules == nil {
                Text("This runner doesn't ask before agents act.").foregroundStyle(.secondary)
            } else {
                Picker("Default mode", selection: Binding { phone.defaultMode } set: { mode in
                    guard let mode else { return }
                    Task {
                        do { try await phone.setDefaultMode(mode); problem = nil } catch { problem = error.localizedDescription }
                    }
                }) {
                    ForEach(RunnerMode.allCases) { mode in
                        Text(mode.label).tag(RunnerMode?.some(mode))
                    }
                }
                if let mode = phone.defaultMode {
                    Text(mode.help).font(.footnote).foregroundStyle(.secondary)
                }
                if let rules, rules.isEmpty {
                    Text("No saved rules").foregroundStyle(.secondary)
                }
                ForEach(rules ?? []) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.rule).font(.subheadline.monospaced())
                            Text([rule.decision == "deny" ? "Denied" : "Allowed", rule.repo].compactMap(\.self).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", systemImage: "minus.circle") { remove([rule.id]) }
                            .labelStyle(.iconOnly).foregroundStyle(.red).buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(rule.rule)")
                    }
                }
                .onDelete { offsets in remove(offsets.compactMap { rules?[$0].id }) }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Ask: the agent asks before it edits or runs anything. Always allow saves a rule, so it doesn't ask again. Swipe a rule to remove it.")
        }
        .task(id: phone.host) { await load() }
    }

    private func load() async {
        do {
            rules = try await phone.runner.permissionRules()
            problem = nil
        } catch let error as RunnerError where error.status == 404 {
            // A runner without permissions.
            rules = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func remove(_ ids: [String]) {
        Task {
            for id in ids {
                do {
                    try await phone.runner.removeRule(id)
                    rules?.removeAll { $0.id == id }
                    problem = nil
                } catch {
                    problem = error.localizedDescription
                }
            }
        }
    }
}
