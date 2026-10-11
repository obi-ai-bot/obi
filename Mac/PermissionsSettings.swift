import SwiftUI

/// Settings › Permissions: the mode the runner's jobs get when a dispatch doesn't pick one, and
/// the rules Always allow (or Deny) saved there, each with Remove. This Mac's own jobs don't ask
/// yet (#134 brings that).
struct PermissionsSettingsView: View {
    let feed: RunnerFeed
    /// Nil until the runner answered, or when it has no rules to list (older runners).
    @State private var rules: [RunnerRule]?
    @State private var problem: String?

    var body: some View {
        Form {
            Section("Permissions on \(feed.name)") {
                if feed.runner == nil {
                    Text("Set the runner's URL in Settings › General.").foregroundStyle(.secondary)
                } else if feed.defaultMode == nil && rules == nil {
                    Text("This runner doesn't ask before agents act.").foregroundStyle(.secondary)
                } else {
                    Picker("Default mode", selection: Binding { feed.defaultMode } set: { mode in
                        guard let mode else { return }
                        Task {
                            do { try await feed.setDefaultMode(mode); problem = nil } catch { problem = error.localizedDescription }
                        }
                    }) {
                        ForEach(RunnerMode.allCases) { mode in
                            Text(mode.label).tag(RunnerMode?.some(mode))
                        }
                    }
                    if let mode = feed.defaultMode {
                        Text(mode.help).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if let rules {
                Section("Saved rules") {
                    if rules.isEmpty {
                        Text("None yet. Always allow on a permission card saves one.").foregroundStyle(.secondary)
                    }
                    ForEach(rules) { rule in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.rule).font(.body.monospaced())
                                Text([rule.decision == "deny" ? "Denied" : "Allowed", rule.repo].compactMap(\.self).joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") { remove(rule.id) }
                        }
                    }
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task(id: feed.runner?.base) { await load() }
    }

    private func load() async {
        guard let runner = feed.runner else { rules = nil; return }
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
        guard let runner = feed.runner else { return }
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
