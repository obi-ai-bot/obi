import Foundation
import Testing
@testable import ObyEngine
@testable import oby_runner

@MainActor
struct SettingsTests {
    let context = BrainContext(accounts: ["claude": ["Personal"], "codex": ["Luna"]],
                               repos: [], settingModels: ["claude": ["claude-sonnet-5-5"], "codex": ["gpt-6.1-sol"]],
                               settingEfforts: ["claude": ["low", "high"], "codex": ["medium"]], settingAccounts: ["Personal", "Luna"])

    func plan(_ setting: Plan.Setting) -> Plan {
        Plan(action: .setSetting, reply: "", dispatches: [], question: nil, setting: setting)
    }

    /// `GET /v1/settings/models/options` lists Cursor's models, with no efforts (#406).
    @Test func modelsOptionsIncludeCursor() async throws {
        let options = await API.optionsList(cursor: { [CursorModel(id: "auto", name: "Auto"), CursorModel(id: "gpt-5", name: "GPT-5")] })
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        let cursor = try #require(json["cursor"] as? [String: Any])
        let models = cursor["models"] as? [[String: String]]
        #expect(models == [["id": "auto", "name": "Auto"], ["id": "gpt-5", "name": "GPT-5"]])
        #expect((cursor["efforts"] as? [String])?.isEmpty == true)
        // Without a signed-in Cursor account the list is empty, and Claude Code's and Codex's stay.
        let none = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(await API.optionsList(cursor: { [] }))) as? [String: Any])
        #expect(((none["cursor"] as? [String: Any])?["models"] as? [Any])?.isEmpty == true)
        #expect(none["claude"] != nil && none["codex"] != nil)
    }

    /// `PUT /v1/settings/models` takes an optional `cursor`: older clients omit it, and it's an id, never an option.
    @Test func modelsPutTakesCursorOptionally() throws {
        let old = try JSONDecoder().decode(Models.self, from: Data(#"{"claude":{"model":"claude-opus-5-5","effort":"xhigh"},"codex":{"model":"gpt-6.1-sol","effort":"high"}}"#.utf8))
        #expect(old.cursor == nil)
        let new = try JSONDecoder().decode(Models.self, from: Data(#"{"claude":{"model":"claude-opus-5-5","effort":"xhigh"},"codex":{"model":"gpt-6.1-sol","effort":"high"},"cursor":{"model":"gpt-5"}}"#.utf8))
        #expect(new.cursor?.model == "gpt-5")
        var option = new
        option.cursor = Models.CursorChoice(model: "--force")
        #expect(throws: (any Error).self) { try API.change(option) }
        #expect(Models.current.cursor?.model == AgentModels.value("cursor", "model"))
    }

    @Test func cursorTakesAModelAndNoEffort() {
        let models = ["claude": ["claude-sonnet-5-5"], "cursor": ["gpt-5"]]
        let context = BrainContext(accounts: ["cursor": ["Work"]], repos: [], settingModels: models, settingEfforts: ["cursor": []], settingAccounts: ["Work"])
        #expect(plan(Plan.Setting(agent: "cursor", model: "gpt-5")).problems(in: context, canary: "x").isEmpty)
        #expect(!plan(Plan.Setting(agent: "cursor", effort: "high")).problems(in: context, canary: "x").isEmpty)
        #expect(!plan(Plan.Setting(agent: "cursor", model: "gpt-5", complexEffort: "high")).problems(in: context, canary: "x").isEmpty)
    }

    @Test func complexEffortDefaultsMatchTheToolDefaults() {
        #expect(AgentModels.defaults["claude.complexEffort"] == "xhigh")
        #expect(AgentModels.defaults["codex.complexEffort"] == "high")
        #expect(CodexRPC.turnStart(thread: "t", prompt: "complex", model: "gpt-6.1-sol",
                                   effort: AgentModels.defaults["codex.complexEffort"] ?? "")["effort"] as? String == "high")
    }

    static func setting(_ agent: String? = nil, model: String? = nil, effort: String? = nil, maxRunning: Int? = nil, account: String? = nil, lift: Bool? = nil) -> String {
        let quote = { (value: String?) in value.map { "\"\($0)\"" } ?? "null" }
        return "{\"action\":\"set_setting\",\"reply\":\"\",\"question\":null,\"dispatches\":[],\"jobs\":[],\"setting\":{\"agent\":\(quote(agent)),\"model\":\(quote(model)),\"effort\":\(quote(effort)),\"maxRunning\":\(maxRunning.map(String.init) ?? "null"),\"account\":\(quote(account)),\"lift\":\(lift.map(String.init) ?? "null")}}"
    }

    /// A Claude Code and a Codex account can share a name ("Deskree"): the schema's account enum
    /// lists it once, since a JSON Schema enum with a repeated item fails the whole brain call.
    @Test func settingAccountsAreListedOnceInTheSchema() throws {
        func accounts(_ names: [String]) throws -> Any? {
            let context = BrainContext(accounts: ["claude": ["Deskree"], "codex": ["Deskree"]], repos: [], settingAccounts: names)
            let schema = try #require(JSONSerialization.jsonObject(with: Plan.schema(for: context)) as? [String: Any])
            let setting = (schema["properties"] as? [String: Any])?["setting"] as? [String: Any]
            let object = (setting?["anyOf"] as? [[String: Any]])?.first { $0["properties"] != nil }
            return (object?["properties"] as? [String: Any])?["account"]
        }
        let account = try #require(try accounts(["Deskree", "Personal", "Deskree"]) as? [String: Any])
        let choices = (account["anyOf"] as? [[String: Any]])?.compactMap { $0["enum"] as? [String] }.first
        #expect(choices == ["Deskree", "Personal"])
        #expect((try accounts([]) as? [String: Any])?["type"] as? String == "null")
    }

    @Test func validatesChoicesAndMaxRunning() {
        #expect(plan(Plan.Setting(agent: "claude", model: "claude-sonnet-5-5", effort: "high"))
            .problems(in: context, canary: "x").isEmpty)
        #expect(plan(Plan.Setting(maxRunning: 50)).problems(in: context, canary: "x")
            == ["maxRunning goes from 1 to 20"])
        #expect(plan(Plan.Setting(agent: "claude", model: "unknown")).problems(in: context, canary: "x")
            == ["unknown model; choices: claude-sonnet-5-5"])
    }

    @Test func validatesComplexEffortAgainstTheToolsChoices() {
        #expect(plan(Plan.Setting(agent: "codex", complexEffort: "medium"))
            .problems(in: context, canary: "x").isEmpty)
        #expect(plan(Plan.Setting(agent: "codex", complexEffort: "xhigh"))
            .problems(in: context, canary: "x") == ["unknown complex effort; choices: medium"])
    }

    @Test func complexEffortChangesAndRestoresTheToolSetting() async throws {
        let folder = try temporaryFolder()
        let desk = Desk(accounts: AccountStore(root: folder), store: JobStore(url: folder.appending(path: "oby.sqlite")))
        let old = AgentModels.value("codex", "complexEffort")
        let reply = await desk.applySetting(Plan.Setting(agent: "codex", complexEffort: "xhigh"))
        #expect(AgentModels.value("codex", "complexEffort") == "xhigh")
        #expect(reply.contains("complex jobs") && reply.contains("Extra high"))
        UserDefaults.standard.set(old, forKey: "codex.complexEffort")
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
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
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
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
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
        desk.makeBrain = { [brain] (_: String?, _: String?, _: Vault) in [brain] }
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
