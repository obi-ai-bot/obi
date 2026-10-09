import Foundation

/// The model and effort each tool's jobs run with. Settings › Models changes them.
nonisolated enum AgentModels {
    static let defaults = ["claude.model": "claude-opus-5-5", "claude.effort": "xhigh",
                           "codex.model": "gpt-6.1-sol", "codex.effort": "high"]

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
