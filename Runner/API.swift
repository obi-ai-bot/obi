import Foundation
import HTTPTypes
import Hummingbird
import Observation
@testable import ObyEngine

/// The runner's HTTP API, exactly as `docs/runner-api.md` describes it. The desk lives on the main
/// actor, so every handler hops there.
@MainActor
final class API {
    static let version = "0.2.0"

    let desk: Desk
    var updates: Updates?
    let speech: Speech
    let devices: Devices
    /// Push to the iPhone (Live Activity and alerts), or nil when this runner has none.
    let push: Push?
    /// When Clear done was last pressed, on any app (Runner/Cleared.swift).
    let cleared: Cleared
    /// Connected apps, used by agents through the broker (Runner/Broker.swift).
    let broker: Broker
    /// Everyone following `GET /v1/events`.
    private var streams: [UUID: AsyncStream<String>.Continuation] = [:]
    /// The accounts as last sent, so an unchanged list isn't sent again.
    private var sentAccounts = Data()
    /// Keeps the cap on running jobs (`PUT /v1/settings/jobs`). Tests put in their own.
    var saveMaxRunning: (Int) -> Void = JobSlots.save

    /// Without `cleared` (the tests), the clear time lives in memory only; without `broker`, so do
    /// the connections and their use log.
    init(desk: Desk, devices: Devices, push: Push? = nil, cleared: Cleared? = nil, speech: Speech = Speech(), broker: Broker? = nil) {
        self.speech = speech
        self.desk = desk
        self.devices = devices
        self.push = push
        self.cleared = cleared ?? Cleared(file: nil)
        self.broker = broker ?? Broker(desk: desk, connections: ConnectionStore(file: nil), uses: UseLog(file: nil), base: "http://127.0.0.1:7777")
        sentAccounts = (try? Self.encode(accounts)) ?? Data()
        desk.onJobChange = { [weak self] job in
            self?.send("job", JobJSON(job: job))
            self?.push?.changed()
        }
        desk.onInboxChange = { [weak self] item in self?.send("inbox", InboxJSON(item: item)) }
        desk.onCheckChange = { [weak self] check in self?.send("check", MacCheckJSON(check: check)) }
        desk.onTurnChange = { [weak self] turn in self?.send("turn", TurnJSON(turn: turn)) }
        watchAccounts()
    }

    /// Every endpoint, behind the owner check.
    nonisolated func router(owner: String) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: Gate(owner: owner))
        router.post("v1/speech") { request, _ in
            try await Self.json(self.speech.handle(request, repos: self.desk.repos))
        }
        router.get("v1/status") { _, _ in await self.status() }
        router.post("v1/plans") { request, _ in try await self.plan(try await Self.decode(PlanRequest.self, from: request)) }
        router.get("v1/conversation") { request, _ in
            try await self.conversation(before: request.uri.queryParameters.get("before").map { String($0) },
                                        limit: request.uri.queryParameters.get("limit", as: Int.self))
        }
        router.post("v1/jobs") { request, _ in try await self.dispatch(try await Self.decode(DispatchRequest.self, from: request)) }
        router.get("v1/jobs") { request, _ in await self.jobs(limit: request.uri.queryParameters.get("limit", as: Int.self) ?? 50) }
        router.get("v1/jobs/:id") { _, context in try await self.job(context.parameters.require("id")) }
        router.get("v1/jobs/:id/wait") { _, context in try await self.wait(context.parameters.require("id")) }
        router.post("v1/jobs/:id/stop") { _, context in try await self.stop(context.parameters.require("id")) }
        router.post("v1/stop-all") { _, _ in await self.stopAll() }
        router.post("v1/jobs/:id/dismiss") { _, context in try await self.dismiss(context.parameters.require("id")) }
        router.post("v1/jobs/:id/move") { request, context in
            try await self.move(context.parameters.require("id"), try await Self.decode(MoveRequest.self, from: request))
        }
        router.post("v1/jobs/:id/start") { _, context in try await self.startNow(context.parameters.require("id")) }
        router.post("v1/jobs/:id/start-when") { request, context in
            try await self.startWhen(context.parameters.require("id"), try await Self.decode(StartWhenRequest.self, from: request))
        }
        router.post("v1/jobs/:id/mode") { request, context in
            try await self.mode(context.parameters.require("id"), try await Self.decode(ModeJSON.self, from: request))
        }
        router.post("v1/jobs/:id/permission") { request, context in
            try await self.permission(context.parameters.require("id"), try await Self.decode(PermissionAnswer.self, from: request))
        }
        router.post("v1/jobs/:id/messages") { request, context in
            try await self.message(context.parameters.require("id"), try await Self.decode(NewMessage.self, from: request))
        }
        router.get("v1/jobs/:id/publish") { _, context in try await self.publishAction(context.parameters.require("id")) }
        router.post("v1/jobs/:id/publish") { request, context in
            try await self.publish(context.parameters.require("id"), try await Self.decode(Approval.self, from: request))
        }
        router.post("v1/clear") { _, _ in try await self.clear() }
        router.post("v1/accounts/:id/reserve") { request, context in
            try await self.reserve(context.parameters.require("id"), try await Self.decode(ReserveRequest.self, from: request))
        }
        router.get("v1/inbox") { request, _ in
            try await self.inbox(state: request.uri.queryParameters.get("state").map { String($0) },
                                 limit: request.uri.queryParameters.get("limit", as: Int.self))
        }
        router.post("v1/inbox/:id/answer") { request, context in
            try await self.answer(context.parameters.require("id"), try await Self.decode(InboxAnswer.self, from: request))
        }
        router.get("v1/events") { _, _ in await self.events() }
        router.get("v1/failures") { request, _ in await self.failures(limit: request.uri.queryParameters.get("limit", as: Int.self) ?? 50) }
        router.get("v1/failures/:id") { _, context in try await self.failure(context.parameters.require("id")) }
        router.post("v1/failures/:id/fix") { _, context in try await self.fix(context.parameters.require("id")) }
        router.get("v1/checks/next") { request, _ in
            await self.nextCheck(mac: request.uri.queryParameters.get("mac").map { String($0) },
                                 kinds: request.uri.queryParameters.get("kinds").map { String($0) })
        }
        router.get("v1/checks/:id/bundle") { _, context in try await self.bundle(context.parameters.require("id")) }
        // An agent's `oby-check apple`, with its job's token rather than the owner's login (`Gate`).
        router.post("v1/agent/apple-check") { request, _ in try await self.appleCheck(request.headers[.authorization], ask: true) }
        router.get("v1/agent/apple-check") { request, _ in try await self.appleCheck(request.headers[.authorization], ask: false) }
        // Connected apps: an agent's MCP endpoint, with its job's token rather than the owner's login.
        router.post("v1/agent/mcp/:job") { request, context in
            var request = request
            let body = try await request.collectBody(upTo: 4 << 20)
            return try await self.mcp(context.parameters.require("job"), request.headers[.authorization], body)
        }
        router.get("v1/agent/mcp/:job") { _, _ in Response(status: .methodNotAllowed) }
        router.delete("v1/agent/mcp/:job") { _, _ in Response(status: .methodNotAllowed) }
        router.get("v1/connections") { _, _ in await self.connections() }
        router.post("v1/connections") { request, _ in try await self.connect(try await Self.decode(NewConnection.self, from: request)) }
        router.delete("v1/connections/:name") { request, context in
            var request = request
            // The body is optional: without one, the answer says what to approve.
            let body = try await request.collectBody(upTo: 64 * 1024)
            let removal = body.readableBytes == 0 ? ConnectionRemoval() : try? JSONDecoder().decode(ConnectionRemoval.self, from: Data(body.readableBytesView))
            guard let removal else { throw APIError(.badRequest, "That isn't the JSON \(request.uri.path) takes.") }
            return try await self.disconnect(context.parameters.require("name"), removal.approval)
        }
        router.post("v1/checks/:id/result") { request, context in
            try await self.checkResult(context.parameters.require("id"), try await Self.decode(MacCheck.Report.self, from: request))
        }
        router.post("v1/devices") { request, _ in try await self.register(try await Self.decode(NewDevice.self, from: request)) }
        router.post("v1/activities") { request, _ in try await self.activity(try await Self.decode(Push.Token.self, from: request)) }
        router.post("v1/notifications") { request, _ in try await self.notifications(try await Self.decode(NotificationToken.self, from: request)) }
        router.get("v1/settings/models") { _, _ in Self.json(Models.current) }
        router.put("v1/settings/models") { request, _ in try Self.change(try await Self.decode(Models.self, from: request)) }
        router.get("v1/settings/models/options") { _, _ in await Self.options() }
        router.get("v1/settings/jobs") { _, _ in await self.jobSettings() }
        router.put("v1/settings/jobs") { request, _ in try await self.change(try await Self.decode(JobSettings.self, from: request)) }
        router.get("v1/settings/permissions") { _, _ in await self.permissionSettings() }
        router.put("v1/settings/permissions") { request, _ in try await self.changePermissions(try await Self.decode(ModeJSON.self, from: request)) }
        router.get("v1/permissions/rules") { _, _ in await self.rules() }
        router.delete("v1/permissions/rules/:id") { _, context in try await self.forget(context.parameters.require("id")) }
        return router
    }

    // MARK: Endpoints

    func status() -> Response {
        Self.json(Status(runner: .init(version: Self.version, host: ProcessInfo.processInfo.hostName, update: updates?.status),
                         accounts: accounts, models: .current, maxRunning: desk.maxRunning, running: desk.runningCount, clearedAt: cleared.at,
                         github: (GitHubApp.inUse ? GitHubActor.app : .owner).rawValue, checks: GitHubApp.checks,
                         permissions: ModeJSON(mode: desk.defaultMode.rawValue)))
    }

    /// Clear done, on the iPhone or the Mac: the runner records now, answers it, and tells every
    /// app following events, so the others hide the same finished jobs at once.
    func clear() throws -> Response {
        let time: Date
        do {
            time = try cleared.clear()
        } catch {
            throw APIError(.internalServerError, "The runner couldn't save the clear: \(error.localizedDescription)")
        }
        let answer = ClearedJSON(clearedAt: time)
        send("clear", answer)
        return Self.json(answer)
    }

    /// One turn of the conversation. The client may send the recent turns it shows; the brain
    /// reads them as the conversation so far, else the runner's own. Either way the exchange joins
    /// the runner's conversation, and the work it plans starts (#269): the answer carries the jobs.
    func plan(_ request: PlanRequest) async throws -> Response {
        let words = request.said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return Self.json(PlanAnswer(.none)) }
        let turns = try request.turns.map(Self.turns)
        let said = request.answer.map { Desk.answered(words, question: $0.question, option: $0.option) } ?? words
        let (talk, started) = await desk.exchange(said, shown: request.answer?.option, turns: turns)
        return Self.json(PlanAnswer(talk, started: started))
    }

    /// One page of the conversation, oldest first: the latest `limit` turns (50 unless asked,
    /// at most `Conversation.stored`), or the ones before the turn `before` names. Fewer than
    /// `limit` means there are no older ones.
    func conversation(before: String?, limit: Int?) throws -> Response {
        let limit = min(max(limit ?? 50, 1), Conversation.stored)
        let before = before.flatMap { $0.isEmpty ? nil : $0 }
        guard let turns = desk.conversation(before: before, limit: limit) else {
            throw APIError(.notFound, "There's no turn \(before ?? "") in the conversation.")
        }
        return Self.json(turns.map(TurnJSON.init))
    }

    /// The client's recent turns, checked: at most `Conversation.kept`, each from the user or Oby,
    /// with 1 to 2,000 characters.
    nonisolated static func turns(_ sent: [PlanRequest.Turn]) throws -> [Turn] {
        guard sent.count <= Conversation.kept else { throw APIError(.unprocessableContent, "turns holds at most \(Conversation.kept) turns.") }
        return try sent.map { turn in
            guard let who = Turn.Who(rawValue: turn.who) else { throw APIError(.unprocessableContent, "A turn's who is user or oby.") }
            let text = turn.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (1...2000).contains(text.count) else { throw APIError(.unprocessableContent, "A turn's text is 1 to 2,000 characters.") }
            return Turn(who: who, text: text)
        }
    }

    /// `POST /v1/jobs`: a whole job to start (#269). A body with a draft's id and no work of its
    /// own is from before Oby started planned work by itself: `410`, with where it went.
    func dispatch(_ request: DispatchRequest) async throws -> Response {
        guard var new = request.job.new else {
            if request.job.id != nil {
                throw APIError(.gone, "Oby starts planned work by itself now: POST /v1/plans starts it and answers the jobs. POST /v1/jobs takes a whole job (repo, kind, task).")
            }
            throw APIError(.unprocessableContent, "A job needs repo, kind and task.")
        }
        new.mode = try request.job.mode.map { try Self.mode($0) }
        do {
            return Self.json(JobJSON(job: try await desk.dispatch(new)), status: .created)
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
    }

    func jobs(limit: Int) -> Response {
        Self.json(desk.jobs.prefix(max(0, limit)).map { JobJSON(job: $0) })
    }

    func job(_ id: String) throws -> Response {
        Self.json(JobJSON(job: try known(id)))
    }

    /// Answers once the job has ended, with the job. The iPhone waits on this as a background
    /// download, which iOS keeps going while Oby is suspended and which wakes Oby when it's
    /// answered, so its Live Activity can say how the job ended. A space every 15 seconds keeps
    /// the connection open through proxies (JSON allows whitespace before the value).
    func wait(_ id: String) throws -> Response {
        _ = try known(id)
        return Response(status: .ok, headers: [.contentType: "application/json", .cacheControl: "no-cache"],
                        body: ResponseBody { writer in
                            var seconds = 0
                            // ponytail: looks once a second; a continuation per job if many phones wait
                            while await self.isRunning(id) {
                                if seconds % 15 == 0 { try await writer.write(ByteBuffer(string: " ")) }
                                try await Task.sleep(for: .seconds(1))
                                seconds += 1
                            }
                            if let json = await self.jobJSON(id) { try await writer.write(ByteBuffer(string: json)) }
                            try await writer.finish(nil)
                        })
    }

    /// A job that already ended comes back as it is.
    func stop(_ id: String) throws -> Response {
        let job = try known(id)
        desk.stop(id)
        return Self.json(JobJSON(job: desk.job(id) ?? job))
    }

    /// Stop all (⌃⌥⌘. on the Mac, the iPhone's Stop all): every queued and running job stops now,
    /// its agent ends within 2 seconds, and nothing it left half-done is published. Answers with the
    /// jobs it stopped.
    func stopAll() -> Response {
        let ids = desk.active.map(\.id)
        desk.stopAll()
        return Self.json(StoppedAll(stopped: ids.count, jobs: ids.compactMap { desk.job($0) }.map { JobJSON(job: $0) }))
    }

    /// The user lets go of a job that needs them: it then needs nothing. No signature: nothing goes out.
    func dismiss(_ id: String) throws -> Response {
        _ = try known(id)
        do {
            try desk.dismiss(id)
        } catch {
            throw APIError(.conflict, error.localizedDescription)
        }
        return Self.json(JobJSON(job: try known(id)))
    }

    /// Moves a job to another tool, account or model (Engine/Move.swift): a queued one starts
    /// there, a running one starts its round over there, a finished one's next round runs there.
    func move(_ id: String, _ request: MoveRequest) throws -> Response {
        _ = try known(id)
        do {
            return Self.json(JobJSON(job: try desk.move(id, to: MoveTarget(agent: request.agent, account: request.account, model: request.model), why: request.why)))
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
    }

    /// Start now (#216): a job waiting for its `startWhen` starts as if it had come.
    func startNow(_ id: String) throws -> Response {
        _ = try known(id)
        do {
            try desk.startNow(id)
        } catch {
            throw APIError(.conflict, error.localizedDescription)
        }
        return Self.json(JobJSON(job: try known(id)))
    }

    /// What a job that hasn't started waits for, replaced (#216); an empty list starts it now.
    func startWhen(_ id: String, _ request: StartWhenRequest) throws -> Response {
        _ = try known(id)
        do {
            return Self.json(JobJSON(job: try desk.setStartWhen(id, request.startWhen)))
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
    }

    /// "Use anyway" (#278): the account takes automatic work past its weekly reserve until its
    /// week resets, or, with `lift` false, is reserved again now. Jobs and reviews waiting for
    /// room look again at once.
    func reserve(_ id: String, _ request: ReserveRequest) throws -> Response {
        guard let state = desk.liftReserve(id, request.lift) else { throw APIError(.notFound, "There's no account \(id).") }
        return Self.json(AccountJSON(state: state))
    }

    /// Words for the job's agent: a running job hears them now, a finished one runs again.
    func message(_ id: String, _ message: NewMessage) throws -> Response {
        _ = try known(id)
        do {
            try desk.message(id, message.text)
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
        return Self.json(JobJSON(job: try known(id)))
    }

    /// The job's mode changes: a waiting permission the new mode allows is answered, and a plan
    /// waiting for approval is approved in it.
    func mode(_ id: String, _ body: ModeJSON) throws -> Response {
        _ = try known(id)
        let mode = try Self.mode(body.mode)
        do {
            try desk.setMode(id, mode)
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
        return Self.json(JobJSON(job: try known(id)))
    }

    /// The user answers the job's waiting permission: allow, always (a rule for the repository) or deny.
    func permission(_ id: String, _ answer: PermissionAnswer) throws -> Response {
        let job = try known(id)
        guard let decision = PermissionDecision(rawValue: answer.decision) else {
            throw APIError(.unprocessableContent, "decision is allow, always or deny.")
        }
        guard job.permission?.id == answer.id else { throw APIError(.conflict, "That permission isn't waiting any more.") }
        do {
            try desk.answerPermission(id, answer.id, decision, message: answer.message)
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
        return Self.json(JobJSON(job: try known(id)))
    }

    func permissionSettings() -> Response {
        Self.json(ModeJSON(mode: desk.defaultMode.rawValue))
    }

    /// Settings › Permissions: the mode new jobs get.
    func changePermissions(_ body: ModeJSON) throws -> Response {
        desk.defaultMode = try Self.mode(body.mode)
        return permissionSettings()
    }

    func rules() -> Response {
        Self.json(desk.permissionRules)
    }

    /// Forgets a saved rule: answers with the rules left.
    func forget(_ id: String) throws -> Response {
        do {
            try desk.forgetRule(id)
        } catch {
            throw APIError(.notFound, error.localizedDescription)
        }
        return rules()
    }

    nonisolated static func mode(_ name: String) throws -> PermissionMode {
        guard let mode = PermissionMode(rawValue: name) else { throw APIError(.unprocessableContent, "mode is ask, acceptEdits, plan or bypass.") }
        return mode
    }

    /// What only the user can answer and hasn't settled, the longest-waiting first. Items put off
    /// until later are in it too, saying so.
    /// With `state` `done`, the history instead (#215): settled items and the reports that arrived
    /// done (an audit's repairs, a failure whose fix was under way), the latest settled first, at most `limit`.
    func inbox(state: String? = nil, limit: Int? = nil) throws -> Response {
        switch state ?? "open" {
        case "open": return Self.json(desk.inbox.filter(\.isOpen).map { InboxJSON(item: $0) })
        case "done":
            let done = desk.inbox.filter { !$0.isOpen }.sorted { ($0.done ?? $0.created) > ($1.done ?? $1.created) }
            return Self.json(done.prefix(min(max(limit ?? 50, 0), 1000)).map { InboxJSON(item: $0) })
        default: throw APIError(.unprocessableContent, "state is open or done.")
        }
    }

    /// The user settles an inbox item: answers it (the answer goes to its job), marks it done, or
    /// puts it off until later.
    func answer(_ id: String, _ answer: InboxAnswer) async throws -> Response {
        guard let item = desk.item(id) else { throw APIError(.notFound, "There's no inbox item \(id).") }
        guard item.isOpen else { throw APIError(.conflict, "That's done already.") }
        let how: Desk.Settle
        switch (answer.answer, answer.done, answer.later) {
        case (let words?, nil, nil): how = .answer(words)
        case (nil, true?, nil): how = .done
        case (nil, nil, let later?):
            guard let date = try? Date(later, strategy: .iso8601) else { throw APIError(.unprocessableContent, "later is a date, like 2026-10-10T09:00:00Z.") }
            how = .later(date)
        default: throw APIError(.unprocessableContent, "Send one of answer, done or later.")
        }
        do {
            // Fix it, or Dismiss, on a failure's item (Engine/Failures.swift).
            if item.kind == .failure, case .answer(let words) = how { return Self.json(InboxJSON(item: try desk.failureLog.answer(id, words))) }
            return Self.json(InboxJSON(item: try await desk.answer(id, how)))
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
    }

    /// The failure records, newest first, with their post-mortems (Engine/Failures.swift), at most 1,000.
    func failures(limit: Int) -> Response {
        Self.json(desk.failureLog.store.failures(limit: min(max(0, limit), 1000)).map(FailureJSON.init))
    }

    func failure(_ id: String) throws -> Response {
        guard let record = desk.failureLog.store.failure(id) else { throw APIError(.notFound, "There's no failure \(id).") }
        return Self.json(FailureJSON(record: record))
    }

    /// Fix it: the fix job starts in Oby's repository, with the post-mortem as its brief.
    func fix(_ id: String) throws -> Response {
        do {
            return Self.json(JobJSON(job: try desk.failureLog.fix(id)), status: .created)
        } catch let unknown as Failures.Unknown {
            throw APIError(.notFound, unknown.localizedDescription)
        } catch {
            throw APIError(.conflict, error.localizedDescription)
        }
    }

    /// A Mac that runs merge checks asks for the next one (Engine/Checks.swift): the oldest queued
    /// check, now that Mac's, or none. `kinds` (`merge,apple`) says which it takes: merge checks
    /// only when it says nothing, as Macs from before Apple checks do.
    func nextCheck(mac: String?, kinds: String? = nil) -> Response {
        let name = mac.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }.flatMap { $0.isEmpty ? nil : $0 } ?? MacCheck.unnamedMac
        let taken = kinds.map { Set($0.split(separator: ",").compactMap { MacCheck.Kind(rawValue: String($0)) }) } ?? [.merge]
        return Self.json(CheckAnswer(check: desk.nextMacCheck(mac: name, kinds: taken).map(MacCheckJSON.init)))
    }

    /// The commits of an Apple check, as a git bundle, for the Mac that took it (empty when the
    /// commit is on its base already).
    func bundle(_ id: String) async throws -> Response {
        let data: Data
        do {
            data = try await desk.appleBundle(id)
        } catch let unknown as MacCheck.Unknown {
            throw APIError(.notFound, unknown.localizedDescription)
        } catch {
            throw APIError(.conflict, error.localizedDescription)
        }
        return Response(status: .ok, headers: [.contentType: "application/octet-stream"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// An agent asks for an Apple check of its worktree's commit (`ask`), or where its latest one
    /// is (Engine/AppleChecks.swift). Only with its job's token (its agent's, or its final check's), while the job runs.
    func appleCheck(_ authorization: String?, ask: Bool) async throws -> Response {
        let token = authorization.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst("Bearer ".count)) : nil } ?? ""
        guard let asker = AppleCheck.asker(forToken: token) else {
            throw APIError(.unauthorized, "oby-check works only inside an Oby job on the runner.")
        }
        let id = asker.job
        if ask {
            do {
                // The job's final check waits for a Mac longer than its agent does (#68).
                _ = try await desk.askAppleCheck(id, final: asker.final)
            } catch {
                throw APIError(.conflict, error.localizedDescription)
            }
        }
        guard let check = desk.appleCheck(id) else { throw APIError(.notFound, "This job hasn't asked for an Apple check.") }
        let line = AppleCheck.line(check, busy: desk.busyMac().flatMap { $0.id == check.id ? nil : $0 })
        let report: String?
        do {
            // What the build printed goes to the agent with the vault's secrets taken out.
            report = try AppleCheck.report(check, log: desk.appleLogs[check.id]).map { try desk.vault.forAgent($0) }
        } catch {
            throw APIError(.serviceUnavailable, "The runner can't read its vault: \(error.localizedDescription)")
        }
        return Self.json(AppleCheckAnswer(check: MacCheckJSON(check: check), line: line, report: report))
    }

    /// One MCP message from job `id`'s agent to the broker (Runner/Broker.swift), only with that
    /// job's token while it runs: `202` for a notification, else the answer.
    func mcp(_ id: String, _ authorization: String?, _ body: ByteBuffer) async throws -> Response {
        let token = authorization.flatMap { $0.hasPrefix("Bearer ") ? String($0.dropFirst("Bearer ".count)) : nil } ?? ""
        guard broker.allows(token, job: id) else {
            throw APIError(.unauthorized, "Oby's broker answers only the agent of a running job, with that job's token.")
        }
        guard let answer = await broker.handle(Data(body.readableBytesView), job: id) else { return Response(status: .accepted) }
        let data = (try? JSONSerialization.data(withJSONObject: answer, options: [.withoutEscapingSlashes])) ?? Data()
        return Response(status: .ok, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    /// The connections, never a secret's value: whether the vault has the secret, and when each was last used.
    func connections() -> Response {
        let saved = Set((try? desk.vault.names()) ?? [])
        return Self.json(broker.connections.all.map { ConnectionJSON($0, saved: saved.contains($0.secret), lastUsed: broker.uses.lastUsed[$0.name]) })
    }

    /// Adds a connection, or replaces the one with its name, once a registered phone signed the
    /// runner's sentence for it (`Connection.action`): agents share the runner's machine and reach
    /// this API as the owner, and a connection they made could carry any secret to their own host.
    /// Without an approval, `403` says what to approve. The secret is named, never sent: it goes in
    /// the vault with `oby-runner vault add`.
    func connect(_ new: NewConnection) throws -> Response {
        guard new.value == nil else {
            throw APIError(.unprocessableContent, "A secret's value never goes through the API: add it on the runner with oby-runner vault add \(new.secret).")
        }
        let connection = Connection(name: new.name, mcp: new.mcp, api: new.api, secret: new.secret, header: new.header)
        if let problem = connection.problem { throw APIError(.unprocessableContent, problem) }
        guard let approval = new.approval else { return Self.approve(connection.action) }
        try devices.checkConnection(approval, action: connection.action)
        do {
            try broker.connections.save(connection)
        } catch {
            throw APIError(.unprocessableContent, error.localizedDescription)
        }
        let saved = ((try? desk.vault.names()) ?? []).contains(connection.secret)
        return Self.json(ConnectionJSON(connection, saved: saved, lastUsed: broker.uses.lastUsed[connection.name]), status: .created)
    }

    /// Removes a connection, once a registered phone signed `Connection.removal`. Its secret stays in the vault.
    func disconnect(_ name: String, _ approval: Approval?) throws -> Response {
        guard broker.connections.named(name) != nil else { throw APIError(.notFound, "There's no connection \(name).") }
        guard let approval else { return Self.approve(Connection.removal(name)) }
        try devices.checkConnection(approval, action: Connection.removal(name))
        let removed: Bool
        do {
            removed = try broker.connections.remove(name)
        } catch {
            throw APIError(.internalServerError, "The runner couldn't save the connections: \(error.localizedDescription)")
        }
        guard removed else { throw APIError(.notFound, "There's no connection \(name).") }
        return Self.json(["removed": name])
    }

    /// `403`, with the sentence a registered phone signs to let the change through.
    nonisolated static func approve(_ action: String) -> Response {
        json(["error": "Approve this on your iPhone first: \(action)", "action": action], status: .forbidden)
    }

    /// A Mac's result for a check it took: passed merges, failed goes back to the author.
    func checkResult(_ id: String, _ report: MacCheck.Report) throws -> Response {
        do {
            return Self.json(CheckAnswer(check: MacCheckJSON(check: try desk.macCheckEnded(id, report))))
        } catch let unknown as MacCheck.Unknown {
            throw APIError(.notFound, unknown.localizedDescription)
        } catch {
            throw APIError(.conflict, error.localizedDescription)
        }
    }

    func publishAction(_ id: String) throws -> Response {
        let (job, base) = try publishable(id)
        return Self.json(["action": Publish.action(for: job, base: base), "base": base])
    }

    /// Publishing by hand, for a job whose own publish failed: once a registered phone signed the
    /// runner's own sentence for it, and only that sentence goes through to Publish.
    func publish(_ id: String, _ approval: Approval) async throws -> Response {
        let (job, base) = try publishable(id)
        let action = Publish.action(for: job, base: base)
        try devices.check(approval, job: id, action: action)
        do {
            let url = try await desk.publish(id) { asked in
                guard asked == action else { throw Shell.Failure(message: "Not published: the phone approved something else.") }
            }
            return Self.json(["url": url.absoluteString])
        } catch {
            throw APIError(.conflict, error.localizedDescription)
        }
    }

    func register(_ device: NewDevice) throws -> Response {
        Self.json(["id": try devices.register(name: device.name, publicKey: device.publicKey)])
    }

    /// A Live Activity push token from the phone. `push` says whether the runner will push.
    func activity(_ token: Push.Token) throws -> Response {
        guard ["update", "start"].contains(token.kind) else { throw APIError(.unprocessableContent, "kind is update or start.") }
        guard let push else { return Self.json(["push": false]) }
        var token = token
        token.watch = nil
        return Self.json(["push": try push.register(token)])
    }

    /// The app's device token, for alerts when a job needs the user. `push` says whether the runner will push.
    func notifications(_ token: NotificationToken) throws -> Response {
        guard let push else { return Self.json(["push": false]) }
        return Self.json(["push": try push.register(Push.Token(token: token.token, kind: "alert", topic: token.topic, environment: token.environment))])
    }

    func events() -> Response {
        let stream = follow()
        return Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                        body: ResponseBody { writer in
                            for await event in stream { try await writer.write(ByteBuffer(string: event)) }
                            try await writer.finish(nil)
                        })
    }

    /// Everything the apps are told from now on, as Server-Sent Events text, until the stream is
    /// dropped. `GET /v1/events` writes one of these out; the tests read one directly.
    func follow() -> AsyncStream<String> {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        streams[id] = continuation
        continuation.onTermination = { _ in Task { @MainActor in self.streams[id] = nil } }
        // Something right away, so proxies pass the headers on.
        continuation.yield(": ping\n\n")
        return stream
    }

    /// Keeps event streams open, and finds the ones whose app went away.
    func ping() {
        for stream in streams.values { stream.yield(": ping\n\n") }
    }

    // MARK: Helpers

    private var accounts: [AccountJSON] { desk.accounts.accounts.map(AccountJSON.init) }

    private func isRunning(_ id: String) -> Bool { desk.job(id)?.isActive ?? false }

    private func jobJSON(_ id: String) -> String? {
        desk.job(id).flatMap { try? Self.encode(JobJSON(job: $0)) }.map { String(decoding: $0, as: UTF8.self) }
    }

    private func known(_ id: String) throws -> Job {
        guard let job = desk.job(id) else { throw APIError(.notFound, "There's no job \(id).") }
        return job
    }

    func publishable(_ id: String) throws -> (Job, String) {
        let job = try known(id)
        guard job.canPublish, let base = job.base else {
            throw APIError(.conflict, job.status != .done ? "Nothing to publish: the job hasn't finished." :
                           job.published != nil ? "It's already published, with every commit." : "Nothing to publish: the job made no commits.")
        }
        return (job, base)
    }

    private func send(_ event: String, _ value: some Encodable) {
        guard let data = try? Self.encode(value) else { return }
        send(event, data)
    }

    private func send(_ event: String, _ data: Data) {
        let text = "event: \(event)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
        for stream in streams.values { stream.yield(text) }
    }

    /// Sends `accounts` when sign-ins, usage or running counts change.
    private func watchAccounts() {
        withObservationTracking {
            _ = desk.accounts.accounts
        } onChange: { [weak self] in
            guard let self else { return }
            Task { @MainActor in self.accountsChanged() }
        }
    }

    private func accountsChanged() {
        if let data = try? Self.encode(accounts), data != sentAccounts {
            sentAccounts = data
            send("accounts", data)
        }
        watchAccounts()
    }

    /// The API's JSON: camelCase as Swift spells it, and ISO 8601 dates, with the vault's secrets
    /// taken out of every string. Throws when the vault can't be read: then nothing is sent.
    nonisolated static func encode(_ value: some Encodable, vault: Vault = .shared) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try vault.scrubbed(encoder.encode(value))
    }

    /// The answer as JSON, or 503 with the reason when it can't be written (the vault can't be read).
    nonisolated static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
        let (data, status) = { () -> (Data, HTTPResponse.Status) in
            do {
                return (try encode(value), status)
            } catch {
                let said = (try? JSONSerialization.data(withJSONObject: ["error": "The runner couldn't write its answer: \(error.localizedDescription)"]))
                return (said ?? Data(#"{"error":"The runner couldn't write its answer."}"#.utf8), .serviceUnavailable)
            }
        }()
        return Response(status: status, headers: [.contentType: "application/json"], body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    nonisolated static func decode<T: Decodable>(_ type: T.Type, from request: Request) async throws -> T {
        var request = request
        let body = try await request.collectBody(upTo: 1 << 20)
        do {
            return try JSONDecoder().decode(type, from: Data(body.readableBytesView))
        } catch {
            throw APIError(.badRequest, "That isn't the JSON \(request.uri.path) takes.")
        }
    }

    func jobSettings() -> Response { Self.json(JobSettings(maxRunning: desk.maxRunning)) }

    /// A new cap on running jobs, 1 to 20 (#237): waiting jobs start at once when it goes up; when
    /// it goes down, running jobs carry on and new ones wait until there's room under it.
    func change(_ settings: JobSettings) throws -> Response {
        guard JobSlots.range.contains(settings.maxRunning) else {
            throw APIError(.unprocessableContent, "maxRunning goes from \(JobSlots.range.lowerBound) to \(JobSlots.range.upperBound).")
        }
        saveMaxRunning(settings.maxRunning)
        desk.maxRunning = settings.maxRunning
        return jobSettings()
    }

    nonisolated static func change(_ models: Models) throws -> Response {
        guard AgentModels.claude.contains(where: { $0.0 == models.claude.model }),
              AgentModels.claudeEfforts.contains(models.claude.effort) else {
            throw APIError(.unprocessableContent, "Claude Code has no model \(models.claude.model) with effort \(models.claude.effort).")
        }
        // ponytail: Codex's choices are only checked for shape (they go to Codex as JSON, never as
        // arguments); check them against its model list if a wrong one ever gets through.
        guard [models.codex.model, models.codex.effort].allSatisfy({ $0.wholeMatch(of: /[A-Za-z0-9._-]*/) != nil }) else {
            throw APIError(.unprocessableContent, "That isn't a Codex model and effort.")
        }
        for (agent, choice) in [("claude", models.claude), ("codex", models.codex)] {
            UserDefaults.standard.set(choice.model, forKey: "\(agent).model")
            UserDefaults.standard.set(choice.effort, forKey: "\(agent).effort")
        }
        // Foundation on Linux writes them (to ~/.config/oby-runner.plist) only when asked.
        _ = UserDefaults.standard.synchronize()
        return json(Models.current)
    }

    static func options() async -> Response {
        let claude = AgentModels.claude.map { Options.Model(id: $0.0, name: $0.1) }
        let codex = ((try? await CodexAgent.models(home: nil)) ?? []).map { Options.Model(id: $0.id, name: $0.name, efforts: $0.efforts) }
        return json(Options(claude: .init(models: claude, efforts: AgentModels.claudeEfforts), codex: .init(models: codex)))
    }
}

/// Lets in only the owner, whose login `tailscale serve` puts in every request, and sends every
/// error as `{"error": …}`.
struct Gate<Context: RequestContext>: RouterMiddleware {
    let owner: String

    @concurrent func handle(_ request: Request, context: Context,
                            next: @concurrent (Request, Context) async throws -> Response) async throws -> Response {
        do {
            // An agent's own requests (`API.appleCheck`) carry its job's token instead.
            guard request.uri.path.hasPrefix("/v1/agent/") || request.headers[values: .tailscaleUserLogin] == [owner] else {
                throw APIError(.unauthorized, "This runner answers only its owner.")
            }
            return try await next(request, context)
        } catch let error as APIError {
            return error.response
        } catch let error as HTTPError {
            return APIError(error.status, error.body ?? error.status.reasonPhrase).response
        } catch {
            return APIError(.internalServerError, error.localizedDescription).response
        }
    }
}

extension HTTPField.Name {
    static let tailscaleUserLogin = Self("Tailscale-User-Login")!
}

/// An answer that isn't what was asked for: a status, and one line a person can read.
struct APIError: HTTPResponseError {
    var status: HTTPResponse.Status
    var message: String

    init(_ status: HTTPResponse.Status, _ message: String) {
        self.status = status
        self.message = message
    }

    var response: Response { API.json(["error": message], status: status) }

    func response(from request: Request, context: some RequestContext) throws -> Response { response }
}

// MARK: JSON

struct Status: Encodable {
    struct Runner: Encodable {
        var version: String
        var host: String
        var update: Updates.Status? = nil
    }

    var runner: Runner
    var accounts: [AccountJSON]
    var models: Models
    /// At most this many jobs run at once (#237), and how many slots are taken now.
    var maxRunning: Int
    var running: Int
    /// When Clear done was last pressed, or null: the API promises the key either way.
    var clearedAt: Date?
    /// Who the runner's own GitHub calls act as: "app" (Oby by Deskree) or "owner" (the owner's gh login).
    var github: String = GitHubActor.owner.rawValue
    /// Whether Oby's review and Mac check go on pull requests as check runs: "ok", "missing
    /// permission" (the app lacks Checks: write) or "no app" (`GitHubApp.checks`).
    var checks: String = "no app"
    /// Settings › Permissions: the mode new jobs get.
    var permissions: ModeJSON

    private enum Keys: String, CodingKey { case runner, accounts, models, maxRunning, running, clearedAt, github, checks, permissions }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(runner, forKey: .runner)
        try keys.encode(accounts, forKey: .accounts)
        try keys.encode(models, forKey: .models)
        try keys.encode(maxRunning, forKey: .maxRunning)
        try keys.encode(running, forKey: .running)
        try keys.encode(clearedAt, forKey: .clearedAt)
        try keys.encode(github, forKey: .github)
        try keys.encode(checks, forKey: .checks)
        try keys.encode(permissions, forKey: .permissions)
    }
}

/// A mode, as `POST /v1/jobs/{id}/mode`, Settings › Permissions and the status carry it.
struct ModeJSON: Codable {
    var mode: String
}

/// How `POST /v1/jobs/{id}/permission` answers the job's waiting permission.
struct PermissionAnswer: Decodable {
    var id: String
    var decision: String
    /// The user's words for the agent, with a deny.
    var message: String?
}

/// What `POST /v1/clear` answers and the `clear` event carries.
struct ClearedJSON: Encodable {
    var clearedAt: Date
}

/// One turn of the conversation as `GET /v1/conversation` lists it and the `turn` event carries
/// it: who said it, the words, when, and the jobs it started (always a list, empty for none).
struct TurnJSON: Encodable {
    var turn: Turn

    private enum Keys: String, CodingKey { case id, who, text, at, jobs }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(turn.id, forKey: .id)
        try keys.encode(turn.who, forKey: .who)
        try keys.encode(turn.text, forKey: .text)
        try keys.encode(turn.date, forKey: .at)
        try keys.encode(turn.jobs ?? [], forKey: .jobs)
    }
}

/// How many jobs run at once, as Settings keeps it (`GET` and `PUT /v1/settings/jobs`).
struct JobSettings: Codable {
    var maxRunning: Int
}

/// Each tool's model and effort, as Settings › Models keeps them.
struct Models: Codable {
    struct Choice: Codable {
        var model: String
        var effort: String
    }

    var claude: Choice
    var codex: Choice

    static var current: Models {
        Models(claude: Choice(model: AgentModels.value("claude", "model"), effort: AgentModels.value("claude", "effort")),
               codex: Choice(model: AgentModels.value("codex", "model"), effort: AgentModels.value("codex", "effort")))
    }
}

struct Options: Encodable {
    struct Model: Encodable {
        var id: String
        var name: String
        var efforts: [String]?
    }

    struct Tool: Encodable {
        var models: [Model]
        var efforts: [String]?
    }

    var claude: Tool
    var codex: Tool
}

/// What `POST /v1/stop-all` answers: how many jobs it stopped, and those jobs.
struct StoppedAll: Encodable {
    var stopped: Int
    var jobs: [JobJSON]
}

/// A job with every key the API promises, null where Swift would leave one out.
struct JobJSON: Encodable {
    var job: Job

    private enum Nullable: String, CodingKey { case base, pr, session, started, finished, commits, published, pushed, publishError, summaries, issue, fromPR, rounds, round, check, model, notes, pullRequest, pullRequestError, dismissed, reviewing, review, reviewError, reviewOf, files, lead, claim, outgoing, question, limit, startCommit, macCheck, mergeError, appleCheck, appleRan, tetrix, moves, xcodeCloud, xcodeCloudError, startWhen, waiting, mode, permission, connectionUses }

    private enum Derived: String, CodingKey { case pipeline, title, mergeNeedsYou, reviewNeedsYou, cloudNeedsYou }

    func encode(to encoder: any Encoder) throws {
        // Oby's own review makes no commits; the ones in its worktree are the pull request's. Saying 0
        // keeps apps built before their `canPublish` knew about reviews from offering Publish on them.
        var job = job
        if job.reviewOf != nil { job.commits = 0 }
        try job.encode(to: encoder)
        var derived = encoder.container(keyedBy: Derived.self)
        try derived.encode(job.pipeline, forKey: .pipeline)
        try derived.encode(job.shortTitle, forKey: .title)
        try derived.encode(job.mergeNeedsYou, forKey: .mergeNeedsYou)
        try derived.encode(job.reviewNeedsYou, forKey: .reviewNeedsYou)
        try derived.encode(job.cloudNeedsYou, forKey: .cloudNeedsYou)
        var nulls = encoder.container(keyedBy: Nullable.self)
        if job.base == nil { try nulls.encodeNil(forKey: .base) }
        if job.pr == nil { try nulls.encodeNil(forKey: .pr) }
        if job.session == nil { try nulls.encodeNil(forKey: .session) }
        if job.started == nil { try nulls.encodeNil(forKey: .started) }
        if job.finished == nil { try nulls.encodeNil(forKey: .finished) }
        if job.commits == nil { try nulls.encodeNil(forKey: .commits) }
        if job.published == nil { try nulls.encodeNil(forKey: .published) }
        if job.pushed == nil { try nulls.encodeNil(forKey: .pushed) }
        if job.publishError == nil { try nulls.encodeNil(forKey: .publishError) }
        if job.summaries == nil { try nulls.encodeNil(forKey: .summaries) }
        if job.issue == nil { try nulls.encodeNil(forKey: .issue) }
        if job.fromPR == nil { try nulls.encodeNil(forKey: .fromPR) }
        // Rounds always has a value in the API: 1 when the job doesn't loop.
        try nulls.encode(job.maxRounds, forKey: .rounds)
        try nulls.encode(job.currentRound, forKey: .round)
        if job.check == nil { try nulls.encodeNil(forKey: .check) }
        if job.model == nil { try nulls.encodeNil(forKey: .model) }
        if job.notes == nil { try nulls.encodeNil(forKey: .notes) }
        if job.pullRequest == nil { try nulls.encodeNil(forKey: .pullRequest) }
        if job.pullRequestError == nil { try nulls.encodeNil(forKey: .pullRequestError) }
        if job.dismissed == nil { try nulls.encodeNil(forKey: .dismissed) }
        if job.reviewing == nil { try nulls.encodeNil(forKey: .reviewing) }
        if job.review == nil { try nulls.encodeNil(forKey: .review) }
        if job.reviewError == nil { try nulls.encodeNil(forKey: .reviewError) }
        if job.reviewOf == nil { try nulls.encodeNil(forKey: .reviewOf) }
        if job.files == nil { try nulls.encodeNil(forKey: .files) }
        if job.lead == nil { try nulls.encodeNil(forKey: .lead) }
        if job.claim == nil { try nulls.encodeNil(forKey: .claim) }
        if job.question == nil { try nulls.encodeNil(forKey: .question) }
        if job.limit == nil { try nulls.encodeNil(forKey: .limit) }
        if job.startCommit == nil { try nulls.encodeNil(forKey: .startCommit) }
        if job.xcodeCloud == nil { try nulls.encodeNil(forKey: .xcodeCloud) }
        if job.xcodeCloudError == nil { try nulls.encodeNil(forKey: .xcodeCloudError) }
        if job.macCheck == nil { try nulls.encodeNil(forKey: .macCheck) }
        if job.mergeError == nil { try nulls.encodeNil(forKey: .mergeError) }
        if job.appleCheck == nil { try nulls.encodeNil(forKey: .appleCheck) }
        if job.appleRan == nil { try nulls.encodeNil(forKey: .appleRan) }
        if job.tetrix == nil { try nulls.encodeNil(forKey: .tetrix) }
        if job.startWhen == nil { try nulls.encodeNil(forKey: .startWhen) }
        if job.waiting == nil { try nulls.encodeNil(forKey: .waiting) }
        // Older jobs ran before modes: Oby answered everything, as Bypass does.
        try nulls.encode(job.currentMode, forKey: .mode)
        if job.permission == nil { try nulls.encodeNil(forKey: .permission) }
        // What went out and where it moved are always lists: empty before anything did.
        if job.outgoing == nil { try nulls.encode([Outgoing](), forKey: .outgoing) }
        // So are the calls its agent made to connected apps.
        if job.connectionUses == nil { try nulls.encode([ConnectionUse](), forKey: .connectionUses) }
        if job.moves == nil { try nulls.encode([Job.Move](), forKey: .moves) }
    }
}

/// A failure record with every key the API promises, null where Swift would leave one out.
struct FailureJSON: Encodable {
    var record: FailureRecord

    private enum Nullable: String, CodingKey { case job, repo, rounds, postMortem, studyError, issue, issueError, fix, fixedBy, fixedAt }
    private enum Derived: String, CodingKey { case intervention, tries, acted }

    func encode(to encoder: any Encoder) throws {
        try record.encode(to: encoder)
        var derived = encoder.container(keyedBy: Derived.self)
        try derived.encode(record.isIntervention, forKey: .intervention)
        try derived.encode(record.tries ?? 0, forKey: .tries)
        try derived.encode(record.acted ?? false, forKey: .acted)
        var nulls = encoder.container(keyedBy: Nullable.self)
        if record.job == nil { try nulls.encodeNil(forKey: .job) }
        if record.repo == nil { try nulls.encodeNil(forKey: .repo) }
        if record.rounds == nil { try nulls.encodeNil(forKey: .rounds) }
        if record.postMortem == nil { try nulls.encodeNil(forKey: .postMortem) }
        if record.studyError == nil { try nulls.encodeNil(forKey: .studyError) }
        if record.issue == nil { try nulls.encodeNil(forKey: .issue) }
        if record.issueError == nil { try nulls.encodeNil(forKey: .issueError) }
        if record.fix == nil { try nulls.encodeNil(forKey: .fix) }
        if record.fixedBy == nil { try nulls.encodeNil(forKey: .fixedBy) }
        if record.fixedAt == nil { try nulls.encodeNil(forKey: .fixedAt) }
    }
}

/// What `GET /v1/checks/next` and `POST /v1/checks/{id}/result` answer: a check, or null for none.
struct CheckAnswer: Encodable {
    var check: MacCheckJSON?

    private enum Keys: String, CodingKey { case check }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(check, forKey: .check)
    }
}

/// A Mac check with every key the API promises, null where Swift would leave one out.
struct MacCheckJSON: Encodable {
    var check: MacCheck

    private enum Nullable: String, CodingKey { case started, finished, mac, steps, failures, checkRun, comment, postError, kind }

    func encode(to encoder: any Encoder) throws {
        try check.encode(to: encoder)
        var nulls = encoder.container(keyedBy: Nullable.self)
        // Checks from before Apple checks have no kind: they're merge checks.
        if check.kind == nil { try nulls.encode(MacCheck.Kind.merge, forKey: .kind) }
        if check.started == nil { try nulls.encodeNil(forKey: .started) }
        if check.finished == nil { try nulls.encodeNil(forKey: .finished) }
        if check.mac == nil { try nulls.encodeNil(forKey: .mac) }
        if check.steps == nil { try nulls.encodeNil(forKey: .steps) }
        if check.failures == nil { try nulls.encodeNil(forKey: .failures) }
        if check.checkRun == nil { try nulls.encodeNil(forKey: .checkRun) }
        if check.comment == nil { try nulls.encodeNil(forKey: .comment) }
        if check.postError == nil { try nulls.encodeNil(forKey: .postError) }
    }
}

/// What `POST` and `GET /v1/agent/apple-check` answer: the job's Apple check, where it is in one
/// line, and, once it ended, what `oby-check apple` prints (null before then).
struct AppleCheckAnswer: Encodable {
    var check: MacCheckJSON
    var line: String
    var report: String?

    private enum Keys: String, CodingKey { case check, line, report }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(check, forKey: .check)
        try keys.encode(line, forKey: .line)
        try keys.encode(report, forKey: .report)
    }
}

/// A connection with every key the API promises: never a secret's value.
struct ConnectionJSON: Encodable {
    var connection: Connection
    /// The vault has the secret it names.
    var secretSaved: Bool
    var lastUsed: Date?

    init(_ connection: Connection, saved: Bool, lastUsed: Date?) {
        self.connection = connection
        secretSaved = saved
        self.lastUsed = lastUsed
    }

    private enum Keys: String, CodingKey { case name, mcp, api, secret, header, created, secretSaved, lastUsed }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(connection.name, forKey: .name)
        try keys.encode(connection.mcp, forKey: .mcp)
        try keys.encode(connection.api, forKey: .api)
        try keys.encode(connection.secret, forKey: .secret)
        try keys.encode(connection.header ?? "Authorization", forKey: .header)
        try keys.encode(connection.created, forKey: .created)
        try keys.encode(secretSaved, forKey: .secretSaved)
        try keys.encode(lastUsed, forKey: .lastUsed)
    }
}

/// What `POST /v1/connections` takes. `value` is only there to be refused.
struct NewConnection: Decodable {
    var name: String
    var mcp: String?
    var api: String?
    var secret: String
    var header: String?
    var value: String?
    /// A registered phone's signature over the runner's sentence (`Connection.action`).
    var approval: Approval?
}

/// What `DELETE /v1/connections/{name}` takes: a registered phone's signature over `Connection.removal`.
struct ConnectionRemoval: Decodable {
    var approval: Approval?
}

/// An inbox item with every key the API promises, and its state: `open`, `later` (put off until
/// a time still to come) or `done`.
struct InboxJSON: Encodable {
    var item: InboxItem

    private enum Keys: String, CodingKey { case id, kind, job, title, text, options, details, created, done, later, answer, state, outgoing, headline, happened, recommended, why }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(item.id, forKey: .id)
        try keys.encode(item.kind, forKey: .kind)
        try keys.encode(item.job, forKey: .job)
        try keys.encode(item.title, forKey: .title)
        try keys.encode(item.text, forKey: .text)
        try keys.encode(item.options, forKey: .options)
        // What each option does, as many as `options`, or null.
        try keys.encode(item.details, forKey: .details)
        try keys.encode(item.created, forKey: .created)
        try keys.encode(item.done, forKey: .done)
        try keys.encode(item.later, forKey: .later)
        try keys.encode(item.answer, forKey: .answer)
        try keys.encodeIfPresent(item.outgoing, forKey: .outgoing)
        // Plain words (InboxRewriter), null until they come or when they couldn't: `text` says it then.
        try keys.encode(item.headline, forKey: .headline)
        try keys.encode(item.happened, forKey: .happened)
        try keys.encode(item.recommended, forKey: .recommended)
        try keys.encode(item.why, forKey: .why)
        try keys.encode(item.done != nil ? "done" : item.waiting() ? "open" : "later", forKey: .state)
    }
}

/// How `POST /v1/inbox/{id}/answer` settles an item: exactly one of these.
struct InboxAnswer: Decodable {
    /// One of the item's options, or the user's own words.
    var answer: String?
    /// Done without an answer.
    var done: Bool?
    /// Put off until this time, ISO 8601.
    var later: String?
}

/// What `POST /v1/accounts/{id}/reserve` asks: past the account's weekly reserve until its reset, or not.
struct ReserveRequest: Decodable {
    var lift: Bool
}

struct AccountJSON: Encodable {
    var state: AccountState

    private enum Keys: String, CodingKey {
        case id, agent, name, label, signedIn, fiveHour, sevenDay, fiveHourResets, sevenDayResets, running, fullUntil, tetrix, tetrixJobs, tetrixUsed,
             reserved, reserveLiftedUntil
    }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(state.account.id, forKey: .id)
        try keys.encode(state.account.agent, forKey: .agent)
        try keys.encode(state.account.name, forKey: .name)
        try keys.encode(state.label, forKey: .label)
        try keys.encode(state.signedIn, forKey: .signedIn)
        try keys.encode(state.fiveHour, forKey: .fiveHour)
        try keys.encode(state.sevenDay, forKey: .sevenDay)
        try keys.encode(state.fiveHourResets, forKey: .fiveHourResets)
        try keys.encode(state.sevenDayResets, forKey: .sevenDayResets)
        try keys.encode(state.running, forKey: .running)
        try keys.encode(state.fullUntil, forKey: .fullUntil)
        try keys.encode(state.tetrix, forKey: .tetrix)
        try keys.encode(state.tetrixJobs, forKey: .tetrixJobs)
        try keys.encode(state.tetrixUsed, forKey: .tetrixUsed)
        try keys.encode(state.isReserved(), forKey: .reserved)
        try keys.encode(state.reserveLiftedUntil(), forKey: .reserveLiftedUntil)
    }
}

/// What `POST /v1/plans` answers: a reply with the jobs it started, the brain's question, or
/// nothing. `drafts` is always empty (#269): there's no plan to dispatch any more, and older
/// clients read it as a plan with no jobs.
struct PlanAnswer: Encodable {
    var kind: String
    /// The jobs the turn started, for a reply; always a list.
    var jobs: [JobJSON]
    var drafts: [JobJSON] = []
    var said: String?
    var question: Plan.Question?
    var text: String?

    @MainActor init(_ talk: Desk.Talk, started: [Job] = []) {
        jobs = started.map { JobJSON(job: $0) }
        switch talk {
        case .question(let said, let question):
            kind = "question"
            self.said = said
            self.question = question
        case .reply(let text):
            kind = "reply"
            self.text = text
        case .none, .thinking:
            kind = "none"
        }
    }
}

struct PlanRequest: Decodable {
    struct Answer: Decodable {
        var question: String
        var option: String
    }

    /// One recent turn as the client shows it: `who` is `user` or `oby`.
    struct Turn: Decodable {
        var who: String
        var text: String
    }

    var said: String
    var answer: Answer?
    /// The conversation so far, oldest first, or nil for the runner's own.
    var turns: [Turn]?
}

/// A whole job for `POST /v1/jobs` (#269): the work (`repo`, `kind`, `task`), what it's about
/// (`pr`, `issue`, `title`), and what a client may set (branch, base, account, rounds, check,
/// model, files, startWhen). `id` alone is an older client's draft: refused with `410`.
struct DispatchRequest: Decodable {
    struct Body: Decodable {
        var id: String?
        var repo: String?
        var kind: String?
        var task: String?
        var pr: Int?
        var issue: Int?
        var title: String?
        var branch: String?
        var base: String?
        var account: String?
        var agent: String?
        var rounds: Int?
        var check: String?
        var model: String?
        /// The files the job claims (#209); an empty list claims none, left out its issue's.
        var files: [String]?
        /// What the job waits for before it starts (#216); left out or empty, it starts at once.
        var startWhen: [StartCondition]?
        var request: String?
        /// How the job asks (`ask`, `acceptEdits`, `plan` or `bypass`, #134); left out, Settings' default.
        var mode: String?

        /// The job to start, or nil when the body holds no work of its own. Its mode is checked by the endpoint.
        var new: Desk.NewJob? {
            guard let repo, let kind, let task else { return nil }
            return Desk.NewJob(repo: repo, kind: kind, task: task, pr: pr, issue: issue, title: title, branch: branch, base: base,
                               account: account, agent: agent, rounds: rounds, check: check, model: model, files: files,
                               startWhen: startWhen.flatMap { $0.isEmpty ? nil : $0 }, request: request)
        }
    }

    var job: Body
}

/// A phone's approval to publish one job.
struct Approval: Decodable {
    var device: String
    var action: String
    var signedAt: String
    var signature: String
}

struct NewDevice: Decodable {
    var name: String
    var publicKey: String
}

struct NotificationToken: Decodable {
    var token: String
    var topic: String
    var environment: String
}

/// What `POST /v1/jobs/{id}/start-when` sets a queued job to wait for (#216).
struct StartWhenRequest: Decodable {
    var startWhen: [StartCondition]
}

/// Where `POST /v1/jobs/{id}/move` moves the job: each key optional, at least one of the first three.
struct MoveRequest: Decodable {
    var agent: String?
    var account: String?
    var model: String?
    /// Why, in the user's words: the agent that takes it over hears it.
    var why: String?
}

struct NewMessage: Decodable {
    var text: String
}
