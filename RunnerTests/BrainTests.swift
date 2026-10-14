import Foundation
import Testing
@testable import ObyEngine

/// The brain knows Cursor as a tool (#406).
@MainActor
struct BrainTests {
    /// Every `enum` the schema gives a property called `name`.
    func enums(_ node: Any, named name: String) -> [[String]] {
        var found: [[String]] = []
        if let object = node as? [String: Any] {
            if let properties = object["properties"] as? [String: Any], let property = properties[name] as? [String: Any] {
                if let values = property["enum"] as? [String] { found.append(values) }
                for option in property["anyOf"] as? [[String: Any]] ?? [] {
                    if let values = option["enum"] as? [String] { found.append(values) }
                }
            }
            for value in object.values { found += enums(value, named: name) }
        } else if let list = node as? [Any] {
            for value in list { found += enums(value, named: name) }
        }
        return found
    }

    @Test func cursorInDispatchEnum() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let accounts = AccountStore(root: folder)
        let cursor = try accounts.add(agent: "cursor", name: "Work", payer: "", separateLogins: true)
        accounts.setLabel("Signed in", for: cursor.id)
        let desk = Desk(accounts: accounts, store: JobStore(url: folder.appending(path: "oby.sqlite")))
        desk.repos = ["deskree-inc/oby"]
        let context = desk.brainContext(turns: [])
        #expect(context.accounts.keys.contains("cursor") && context.accounts["cursor"] == ["auto", "Work"])
        let schema = try JSONSerialization.jsonObject(with: Plan.schema(for: context))
        // The dispatch's tool, and set_setting's, and move_job's.
        let tools = enums(schema, named: "agent")
        #expect(tools.contains { $0.contains("cursor") && $0.contains("auto") }, "\(tools)")
        #expect(tools.contains(["claude", "codex", "cursor"]), "\(tools)")
        // The prompt says what "cursor" is.
        #expect(Planner.system(canary: "x").contains("\"cursor\" is Cursor"))
    }
}
