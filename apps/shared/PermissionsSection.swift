#if os(iOS) || os(macOS)
import SwiftUI

/// Settings › Permissions, on the iPhone and in the Mac's Runner tab alike (as the sections in
/// apps/shared/SettingsSections.swift): the mode the runner's jobs get when a dispatch doesn't pick one,
/// and the rules Always allow (or Deny) saved there, each removed with its button (or a swipe on
/// the iPhone).
struct PermissionsSection: View {
    /// The runner, or nil while none is set.
    var runner: Runner?
    /// The default mode, as the runner last said, or nil from a runner without modes.
    var defaultMode: RunnerMode?
    var setDefault: (RunnerMode) async throws -> Void
    /// Nil until the runner answered, or when it has no rules to list (older runners).
    @State private var rules: [RunnerRule]?
    @State private var problem: String?
    @Environment(\.settingsCards) private var cards

    private static let footer = "Ask: the agent asks before it edits or runs anything. Always allow saves a rule, so it doesn’t ask again; remove the rule to be asked again."

    private var mode: Binding<RunnerMode?> {
        Binding { defaultMode } set: { mode in
            guard let mode else { return }
            Task {
                do { try await setDefault(mode); problem = nil } catch { problem = error.localizedDescription }
            }
        }
    }

    var body: some View {
        Group {
            if cards { group } else { section }
        }
        .task(id: runner?.base) { await load() }
    }

    /// Sangam's card: the default mode with what it lets the agent do, then each rule with Remove.
    private var group: some View {
        SetGroup("Permissions", footer: Self.footer, problem: problem) {
            if runner == nil {
                SetRow("Set the runner's address first.", quiet: true)
            } else if defaultMode == nil && rules == nil {
                SetRow("This runner doesn't ask before agents act.", quiet: true)
            } else {
                SetRow("Default mode", about: defaultMode?.help) {
                    SetSelect("Default mode", selection: mode, options: RunnerMode.allCases.map { (RunnerMode?.some($0), $0.label) })
                }
                if let rules, rules.isEmpty {
                    SetRow("No saved rules", quiet: true)
                }
                ForEach(rules ?? []) { rule in
                    SetRow(about: [rule.decision == "deny" ? "Denied" : "Allowed", rule.repo].compactMap(\.self).joined(separator: " · ")) {
                        SetCode(rule.rule)
                    } control: {
                        Button("Remove", role: .destructive) { remove([rule.id]) }
                            .buttonStyle(.set)
                            .accessibilityLabel("Remove \(rule.rule)")
                    }
                }
            }
        }
    }

    private var section: some View {
        Section {
            if runner == nil {
                Text("Set the runner's address first.").foregroundStyle(.secondary)
            } else if defaultMode == nil && rules == nil {
                Text("This runner doesn't ask before agents act.").foregroundStyle(.secondary)
            } else {
                Picker("Default mode", selection: mode) {
                    ForEach(RunnerMode.allCases) { mode in
                        Text(mode.label).tag(RunnerMode?.some(mode))
                    }
                }
                if let mode = defaultMode {
                    Text(mode.help).font(.footnote).foregroundStyle(.secondary)
                }
                if let rules, rules.isEmpty {
                    Text("No saved rules").foregroundStyle(.secondary)
                }
                ForEach(rules ?? []) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.rule).font(.body.monospaced())
                            Text([rule.decision == "deny" ? "Denied" : "Allowed", rule.repo].compactMap(\.self).joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { remove([rule.id]) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Remove \(rule.rule)")
                    }
                }
                .onDelete { offsets in remove(offsets.compactMap { rules?[$0].id }) }
            }
            if let problem { Text(problem).foregroundStyle(.red) }
        } header: {
            Text("Permissions")
        } footer: {
            Text(Self.footer)
        }
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

    private func remove(_ ids: [String]) {
        guard let runner else { return }
        Task {
            for id in ids {
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
}
#endif
