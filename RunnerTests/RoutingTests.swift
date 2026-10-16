import Foundation
import Testing
@testable import ObyEngine

/// Cursor in routing (#406): it reports no usage, so automatic work goes to it last.
struct RoutingTests {
    let now = Date(timeIntervalSince1970: 1_791_582_173)

    func state(_ id: String, _ agent: String, sevenDay: Double? = nil, running: Int = 0, fullUntil: Date? = nil) -> AccountState {
        AccountState(account: Account(id: id, agent: agent, name: id.capitalized, payer: "", home: nil), label: "Pro",
                     sevenDay: sevenDay, sevenDayResets: sevenDay == nil ? nil : now.addingTimeInterval(6 * 86_400),
                     running: running, fullUntil: fullUntil)
    }

    @Test func cursorLastTier() throws {
        // Claude Code is ahead of its weekly pace (60% of its week used with a seventh gone), and
        // that still beats an account whose usage nobody knows.
        let claude = state("claude", "claude", sevenDay: 0.6)
        let cursor = state("cursor", "cursor")
        #expect(claude.isAhead(at: now))
        let route = try #require(AccountStore.choose([cursor, claude], agent: nil, now: now))
        #expect(route.account.id == "claude")
        // With Claude Code full, Cursor takes the work.
        let full = state("claude", "claude", sevenDay: 0.6, fullUntil: now.addingTimeInterval(3600))
        let next = try #require(AccountStore.choose([full, cursor], agent: nil, now: now))
        #expect(next.account.id == "cursor")
        #expect(next.reason == "Cursor reports no usage: fewest jobs running")
        // Even an unreported Claude account (no usage known yet) goes before Cursor.
        #expect(AccountStore.choose([cursor, state("fresh", "claude")], agent: nil, now: now)?.account.id == "fresh")
        // Named, it's the only candidate.
        #expect(AccountStore.choose([claude, cursor], agent: "cursor", now: now)?.account.id == "cursor")
    }

    @Test func amongCursorAccountsTheFewestRunningThenListOrder() throws {
        let accounts = [state("one", "cursor", running: 2), state("two", "cursor", running: 1), state("three", "cursor", running: 1)]
        #expect(AccountStore.choose(accounts, agent: nil, now: now)?.account.id == "two")
        #expect(AccountStore.choose([accounts[0], accounts[2], accounts[1]], agent: nil, now: now)?.account.id == "three")
    }

    @Test func oneCursorWhenSharedLogin() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AccountStore(root: folder)
        _ = try store.add(agent: "cursor", name: "Work", payer: "", separateLogins: false)
        // Cursor keeps one login per Mac user: a second account is refused, saying why.
        #expect(throws: Shell.Failure.self) { try store.add(agent: "cursor", name: "Home", payer: "", separateLogins: false) }
        do {
            _ = try store.add(agent: "cursor", name: "Home", payer: "", separateLogins: false)
        } catch {
            #expect(error.localizedDescription.contains("Cursor keeps one login per Mac user"))
        }
        #expect(store.accounts.filter { $0.account.agent == "cursor" }.count == 1)
        // Other tools aren't limited, and neither is Cursor once the probe shows separate logins.
        _ = try store.add(agent: "claude", name: "Second", payer: "")
        _ = try store.add(agent: "cursor", name: "Home", payer: "", separateLogins: true)
        #expect(store.accounts.filter { $0.account.agent == "cursor" }.count == 2)
        // The probe on tetrix-lab proved separate logins per HOME + XDG_CONFIG_HOME + CURSOR_CONFIG_DIR.
        #expect(CursorFacts.separateLogins == true)
        let more = AccountStore(root: try temporaryFolder())
        _ = try more.add(agent: "cursor", name: "One", payer: "")
        _ = try more.add(agent: "cursor", name: "Two", payer: "")
        #expect(more.accounts.filter { $0.account.agent == "cursor" }.count == 2)
    }
}

/// Cursor's login: what its status says, the sign-in script, its models.
struct CursorAccountTests {
    @Test func statusSaysWhoIsSignedIn() {
        #expect(CursorStatus.parse("✓ Logged in as name@example.com") == .signedIn("name@example.com"))
        #expect(CursorStatus.parse("\u{1B}[32mLogged in as name@example.com\u{1B}[0m\n") == .signedIn("name@example.com"))
        #expect(CursorStatus.parse("Not logged in") == .signedOut)
        #expect(CursorStatus.parse("Authentication tokens stored securely") == .unknown)
        let env = CursorStatus.environment(home: "/h")
        #expect(env["CURSOR_CONFIG_DIR"] == "/h" && env["XDG_CONFIG_HOME"] == "/h/.config" && env["HOME"] == "/h")
        #expect(env.keys.contains("CURSOR_API_KEY") && env.keys.contains("CURSOR_AUTH_TOKEN"))
        // No home of Oby's: Cursor's own, and no variable of its logins.
        #expect(CursorStatus.environment(home: nil)["HOME"] == nil && CursorStatus.environment(home: nil).keys.contains("CURSOR_API_KEY"))
    }

    @Test func signInScriptRunsCursorsLoginOnItsHome() {
        let account = Account(id: "c", agent: "cursor", name: "Work", payer: "Deskree", home: "/Users/x/accounts/c")
        let mac = AccountStore.signInScript(for: account, headless: false)
        #expect(mac.contains("export CURSOR_CONFIG_DIR='/Users/x/accounts/c'\n") && mac.contains("\ncursor-agent login\n"))
        // Its login is a file under XDG_CONFIG_HOME: the account's folders hold it.
        #expect(mac.contains("export XDG_CONFIG_HOME='/Users/x/accounts/c/.config'\n") && mac.contains("export HOME='/Users/x/accounts/c'\n"))
        #expect(!mac.contains("NO_OPEN_BROWSER") && !mac.contains("Open the link"))
        let runner = AccountStore.signInScript(for: account, headless: true)
        #expect(runner.contains("export NO_OPEN_BROWSER=1\n") && runner.contains("Open the link on any device."))
        // Claude's macOS login deliberately denies keychain files (#459), so its credentials
        // stay in the account folder. Other platforms still run the bare login command.
        let claude = AccountStore.signInScript(for: Account(id: "a", agent: "claude", name: "Work", payer: "", home: nil), headless: true)
        #expect(!claude.contains("NO_OPEN_BROWSER"))
        #if os(macOS)
        #expect(claude.contains("sandbox-exec -p") && claude.contains("Library/Keychains") && claude.contains(" claude auth login\n"))
        #else
        #expect(claude.contains("\nclaude auth login\n"))
        #endif
    }

    @Test func tetrixSignInForCursorUsesItsMCPLogin() {
        let script = TetrixUse.signInScript(for: Account(id: "c", agent: "cursor", name: "Work", payer: "", home: "/h"))
        #expect(script.contains("export CURSOR_CONFIG_DIR='/h'") && script.contains("cursor-agent mcp login tetrix"))
        #expect(script.contains("export XDG_CONFIG_HOME='/h/.config'") && script.contains("export HOME='/h'"))
        #expect(TetrixUse.cursorList("tetrix: ready\nother: needs login") == true)
        #expect(TetrixUse.cursorList("tetrix: needs authentication") == false)
        #expect(TetrixUse.cursorList("") == false)
    }

    @Test func modelsParse() {
        let text = "Available models\n\nauto - Auto (current)\ngpt-5 - GPT-5\nsonnet-4.5-thinking - Claude 4.5 Sonnet Thinking (default)\n\nTip: use --model"
        #expect(CursorModels.parse(text) == [CursorModel(id: "auto", name: "Auto"), CursorModel(id: "gpt-5", name: "GPT-5"),
                                             CursorModel(id: "sonnet-4.5-thinking", name: "Claude 4.5 Sonnet Thinking")])
        #expect(AgentModels.defaults["cursor.model"] == "auto")
    }

    @Test func cursorDoesntReportUsage() {
        #expect(!AccountStore.reportsUsage("cursor") && AccountStore.reportsUsage("claude") && AccountStore.reportsUsage("codex"))
    }
}
