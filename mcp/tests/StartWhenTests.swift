import Foundation
import Testing
@testable import oby_mcp

/// oby-mcp's side of starting a job when something happens (#216, docs/mcp.md): dispatch passes
/// `startWhen` to the runner, a job ask started and the job say what they wait for, and `start`
/// starts a waiting job now or changes what it waits for.
@Suite struct StartWhenTests {
    func waitingJob(_ id: String = "ab12cd34") -> JSON {
        var waiting = job(id, status: "queued", stage: 1).object!
        waiting["step"] = "Waiting for #205 to merge"
        waiting["waiting"] = ["kind": "schedule", "text": "for #205 to merge", "job": nil]
        waiting["startWhen"] = [["pr": 205, "is": "merged"]]
        return .object(waiting)
    }

    @Test func dispatchWaitsForWhatItsToldTo() async throws {
        let stub = StubRunner()
        var waiting = job("ab12cd34", status: "queued", stage: 1).object!
        waiting["startWhen"] = [["account": "work", "window": "fiveHour"]]
        stub.answer("POST /v1/plans", ["kind": "reply", "text": "On it: fixing #140 in oby on Codex once it resets.", "jobs": [.object(waiting)], "drafts": []])
        stub.answer("POST /v1/jobs", waitingJob(), status: 201)
        let server = server(stub)

        // A job ask started that waits says what for (#269).
        let asked = await server.call("ask", ["said": "fix oby #140 on Codex when it resets"])
        #expect(asked.text.contains("starts when: account work 5-hour window has room"))
        #expect(asked.text.hasPrefix("Oby started 1 job, queued on the runner (one or more wait for what they're told to; start starts one now)."))

        let conditions: JSON = [["pr": 205, "is": "merged"], ["at": "2026-10-13T09:00:00Z"]]
        let dispatched = await server.call("dispatch", ["repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #140", "issue": 140, "startWhen": conditions])
        #expect(!dispatched.isError, "\(dispatched.text)")
        #expect(dispatched.text.hasPrefix("Started: it's queued on the runner and starts once what it waits for has happened"))
        #expect(stub.calls.last?.body?["job"]?["startWhen"] == conditions)

        // Not a list of objects: refused before the runner hears of it.
        let calls = stub.calls.count
        #expect(await server.call("dispatch", ["repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #140", "startWhen": "tomorrow"]).isError)
        #expect(await server.call("dispatch", ["repo": "deskree-inc/oby", "kind": "fix", "task": "Fix #140", "startWhen": ["tomorrow"]]).isError)
        #expect(stub.calls.count == calls)
    }

    @Test func aWaitingJobSaysWhatFor() async throws {
        let stub = StubRunner()
        stub.answer("GET /v1/jobs/ab12cd34", waitingJob())
        let shown = await server(stub).call("job", ["id": "ab12cd34"])
        #expect(inside(shown.text).first?.contains("waiting: Waiting for #205 to merge") == true)
        #expect(inside(shown.text).first?.contains("starts when: #205 merged") == true)
    }

    @Test func startNowOrChangeWhatItWaitsFor() async throws {
        let stub = StubRunner()
        stub.answer("POST /v1/jobs/ab12cd34/start", job("ab12cd34", status: "queued", stage: 1))
        stub.answer("POST /v1/jobs/ab12cd34/start-when", waitingJob())
        let server = server(stub)

        let started = await server.call("start", ["id": "ab12cd34"])
        #expect(!started.isError && started.text.hasPrefix("Starting it now."))
        #expect(stub.calls.last == .init(method: "POST", path: "/v1/jobs/ab12cd34/start", body: nil))

        let changed = await server.call("start", ["id": "ab12cd34", "startWhen": [["pr": 205]]])
        #expect(!changed.isError && changed.text.hasPrefix("It waits for that now."))
        #expect(stub.calls.last == .init(method: "POST", path: "/v1/jobs/ab12cd34/start-when", body: ["startWhen": [["pr": 205]]]))

        // An empty list starts it now, as the runner does.
        _ = await server.call("start", ["id": "ab12cd34", "startWhen": []])
        #expect(stub.calls.last?.path == "/v1/jobs/ab12cd34/start")
        #expect(await server.call("start", [:]).isError)
    }
}
