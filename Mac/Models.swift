import SwiftUI

/// The model and effort each tool's jobs run with. Settings › Models changes them.
nonisolated enum AgentModels {
    static let defaults = ["claude.model": "claude-opus-5-5", "claude.effort": "xhigh",
                           "codex.model": "gpt-6-sol", "codex.effort": "high"]

    static let claude = [("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
                         ("claude-haiku-5-5", "Haiku 5.5"), ("claude-fable-5-1", "Fable 5.1")]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]

    /// `agent` is "claude" or "codex"; `what` is "model" or "effort".
    static func value(_ agent: String, _ what: String) -> String {
        let key = "\(agent).\(what)"
        return UserDefaults.standard.string(forKey: key) ?? defaults[key] ?? ""
    }

    /// "Opus 5.5 · Extra high"
    static func summary(_ agent: String) -> String {
        let model = value(agent, "model")
        return "\(claude.first { $0.0 == model }?.1 ?? model) · \(effortName(value(agent, "effort")))"
    }

    static func effortName(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }
}

/// Settings › Models: which model and effort Claude Code and Codex jobs use.
struct ModelsSettingsView: View {
    @AppStorage("claude.model") private var claudeModel = AgentModels.defaults["claude.model"] ?? ""
    @AppStorage("claude.effort") private var claudeEffort = AgentModels.defaults["claude.effort"] ?? ""
    @AppStorage("codex.model") private var codexModel = AgentModels.defaults["codex.model"] ?? ""
    @AppStorage("codex.effort") private var codexEffort = AgentModels.defaults["codex.effort"] ?? ""
    /// What the signed-in Codex account offers, from its own model list.
    @State private var codexModels: [CodexModel] = []

    var body: some View {
        Form {
            Section("Claude Code") {
                Picker("Model", selection: $claudeModel) {
                    ForEach(AgentModels.claude, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Effort", selection: $claudeEffort) {
                    ForEach(AgentModels.claudeEfforts, id: \.self) { Text(AgentModels.effortName($0)).tag($0) }
                }
            }
            Section("Codex") {
                Picker("Model", selection: $codexModel) {
                    ForEach(codexChoices, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Effort", selection: $codexEffort) {
                    ForEach(codexEfforts, id: \.self) { Text(AgentModels.effortName($0)).tag($0) }
                }
            }
            Text("New jobs use these. Oby's planner stays on Haiku: it only writes the plan card, so it should be quick.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .task { codexModels = (try? await CodexAgent.models(home: nil)) ?? [] }
    }

    /// The account's models, plus the chosen one while the list loads (or if the plan dropped it).
    private var codexChoices: [CodexModel] {
        codexModels.contains { $0.id == codexModel } ? codexModels
            : [CodexModel(id: codexModel, name: codexModel, efforts: AgentModels.claudeEfforts)] + codexModels
    }

    private var codexEfforts: [String] {
        let efforts = codexChoices.first { $0.id == codexModel }?.efforts ?? []
        return efforts.contains(codexEffort) ? efforts : [codexEffort] + efforts
    }
}
