import Foundation
import Testing
@testable import ObyEngine

@MainActor
struct SettingsTests {
    let context = BrainContext(accounts: ["claude": ["Personal"], "codex": ["Luna"]],
                               repos: [], settingModels: ["claude": ["claude-sonnet-5-5"], "codex": ["gpt-6.1-sol"]],
                               settingEfforts: ["claude": ["low", "high"], "codex": ["medium"]], settingAccounts: ["Personal", "Luna"])

    func plan(_ setting: Plan.Setting) -> Plan {
        Plan(action: .setSetting, reply: "", dispatches: [], question: nil, setting: setting)
    }

    static func setting(_ agent: String? = nil, model: String? = nil, effort: String? = nil, maxRunning: Int? = nil, account: String? = nil, lift: Bool? = nil) -> String {
        let quote = { (value: String?) in value.map { "\"\($0)\"" } ?? "null" }
        return "{\"action\":\"set_setting\",\"reply\":\"\",\"question\":null,\"dispatches\":[],\"jobs\":[],\"setting\":{\"agent\":\(quote(agent)),\"model\":\(quote(model)),\"effort\":\(quote(effort)),\"maxRunning\":\(maxRunning.map(String.init) ?? "null"),\"account\":\(quote(account)),\"lift\":\(lift.map(String.init) ?? "null")}}"
    }

    @Test func validatesChoicesAndMaxRunning() {
        #expect(plan(Plan.Setting(agent: "claude", model: "claude-sonnet-5-5", effort: "high"))
            .problems(in: context, canary: "x").isEmpty)
        #expect(plan(Plan.Setting(maxRunning: 50)).problems(in: context, canary: "x")
            == ["maxRunning goes from 1 to 20"])
        #expect(plan(Plan.Setting(agent: "claude", model: "unknown")).problems(in: context, canary: "x")
            == ["unknown model; choices: claude-sonnet-5-5"])
    }

    @Test func modelAndEffortChangeLandsInSettings() async throws {
        let folder = try temporaryFolder()
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let oldModel = AgentModels.value("claude", "model")
        let oldEffort = AgentModels.value("claude", "effort")
        _ = await desk.applySetting(Plan.Setting(agent: "claude", model: "claude-sonnet-5-5", effort: "high"))
        #expect(AgentModels.value("claude", "model") == "claude-sonnet-5-5")
        #expect(AgentModels.value("claude", "effort") == "high")
        UserDefaults.standard.set(oldModel, forKey: "claude.model")
        UserDefaults.standard.set(oldEffort, forKey: "claude.effort")
    }

    @Test func planTakesTwoToolChangesInOneMessage() async throws {
        let folder = try temporaryFolder()
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        desk.settingModels["codex"] = ["luna"]
        desk.settingEfforts["codex"] = ["max"]
        desk.settingModelEfforts["codex"] = ["luna": ["max"]]
        let brain = ConversationTests.FakeBrain([
            Self.setting("claude", model: "claude-sonnet-5-5", effort: "high"),
            Self.setting("codex", model: "luna"),
            ConversationTests.reply("")
        ])
        desk.makeBrain = { [brain] _, _ in [brain] }
        _ = await desk.plan("Use Sonnet for Claude Code and Luna for Codex")
        #expect(AgentModels.value("claude", "model") == "claude-sonnet-5-5")
        #expect(AgentModels.value("claude", "effort") == "high")
        #expect(AgentModels.value("codex", "model") == "luna")
        UserDefaults.standard.removeObject(forKey: "claude.model")
        UserDefaults.standard.removeObject(forKey: "codex.model")
    }

    @Test func planRefusesAnOutOfRangeCapWithItsLimit() async throws {
        let folder = try temporaryFolder()
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        let brain = ConversationTests.FakeBrain([Self.setting(maxRunning: 50)])
        desk.makeBrain = { [brain] _, _ in [brain] }
        let result = await desk.plan("run 50 jobs")
        guard case .reply(let text) = result else { Issue.record("expected refusal reply"); return }
        #expect(text.contains("1 to 20"))
    }

    @Test func planChangesAndRestoresAReserve() async throws {
        let folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        let account = try accounts.add(agent: "claude", name: "Personal", payer: "")
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        let brain = ConversationTests.FakeBrain([Self.setting(account: "Personal", lift: true), Self.setting(account: "Personal", lift: false), ConversationTests.reply("")])
        desk.makeBrain = { [brain] _, _ in [brain] }
        _ = await desk.plan("lift Personal's reserve and put it back")
        #expect(accounts.state(account.id)?.reserveLifted == nil)
    }

    @Test func reserveCanBeLiftedAndPutBack() async throws {
        let folder = try temporaryFolder()
        let accounts = AccountStore(root: folder)
        let account = try accounts.add(agent: "claude", name: "Personal", payer: "")
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let lifted = await desk.applySetting(Plan.Setting(account: "Personal", lift: true))
        #expect(lifted.contains("Lifted") && accounts.state(account.id)?.reserveLifted != nil)
        let restored = await desk.applySetting(Plan.Setting(account: "Personal", lift: false))
        #expect(restored.contains("Put") && accounts.state(account.id)?.reserveLifted == nil)
    }
}
