import Foundation

/// The model and effort each tool's jobs run with. Settings › Models changes them.
nonisolated enum AgentModels {
    static let defaults = ["claude.model": "claude-opus-5-5", "claude.effort": "xhigh",
                           "claude.complexEffort": "xhigh",
                           "codex.model": "gpt-6.1-sol", "codex.effort": "high", "codex.complexEffort": "high",
                           // Cursor has no effort: "auto" lets Cursor pick the model.
                           "cursor.model": "auto"]

    static let claude = [("claude-fable-5-1", "Fable 5.1"), ("claude-opus-5-5", "Opus 5.5"), ("claude-sonnet-5-5", "Sonnet 5.5"),
                         ("claude-haiku-5-5", "Haiku 5.5")]
    static let claudeEfforts = ["low", "medium", "high", "xhigh", "max"]
    /// What a complex job is offered: Claude Code's strongest model, and Codex's (heavy on a small plan).
    static let stronger = ["claude": "claude-fable-5-1", "codex": "gpt-6-astra"]

    /// `agent` is "claude", "codex" or "cursor"; `what` is "model" or "effort" (Cursor has no effort).
    static func value(_ agent: String, _ what: String) -> String {
        let key = "\(agent).\(what)"
        return UserDefaults.standard.string(forKey: key) ?? defaults[key] ?? ""
    }

    static func effort(_ agent: String, complex: Bool) -> String {
        value(agent, complex ? "complexEffort" : "effort")
    }

    /// "Opus 5.5 · Extra high"
    static func summary(_ agent: String) -> String {
        let model = value(agent, "model")
        return "\(name(model)) · \(effortName(value(agent, "effort")))"
    }

    /// "Opus 5.5" for Claude Code's models; anything else as it is.
    static func name(_ model: String) -> String {
        claude.first { $0.0 == model }?.1 ?? (model == "gpt-6-astra" ? "GPT-6-Astra" : model == "auto" ? "Auto" : model)
    }

    static func effortName(_ effort: String) -> String {
        effort == "xhigh" ? "Extra high" : effort.capitalized
    }
}
