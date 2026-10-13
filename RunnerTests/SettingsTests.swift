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
