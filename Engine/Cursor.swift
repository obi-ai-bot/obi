import Foundation

/// What only a signed-in Cursor can tell (#406, spike #24): the probe's signed-in half
/// (scripts/cursor-probe.sh, docs/cursor.md) decides each one, and its report is committed here.
/// Until then each holds the safe value: what Oby does is true whichever way Cursor behaves.
nonisolated enum CursorFacts {
    /// Two Cursor accounts keep separate logins under their own `CURSOR_CONFIG_DIR`. False: Settings
    /// allows one Cursor account per machine and says why.
    static let separateLogins = false
    /// An edit in `--sandbox disabled` comes to Oby as a permission request. False: a Cursor job in
    /// Ask mode behaves as Accept edits, and the mode picker and the job's card say so.
    static let editsAsk = false
    /// Cursor takes the MCP servers `session/new` carries. False: no server is handed over, and the
    /// job's report says connected apps aren't available to Cursor jobs yet.
    static let honoursMcpServers = false
    /// Cursor offers its model as a `model` config option, set after `session/new`. False: `--model`.
    static let modelOption = false

    /// Why Settings allows one Cursor account.
    static let oneLogin = "Cursor keeps one login per Mac user"
    /// What a Cursor job in Ask mode and its mode picker say when Cursor writes without asking.
    static let askActsAsAcceptEdits = "Cursor edits files without asking Oby, so Ask works as Accept edits for Cursor jobs"
    static let noConnectedApps = "Connected apps aren't available to Cursor jobs yet"
}
