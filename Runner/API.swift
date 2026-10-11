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
    /// Everyone following `GET /v1/events`.
    private var streams: [UUID: AsyncStream<String>.Continuation] = [:]
    /// The accounts as last sent, so an unchanged list isn't sent again.
    private var sentAccounts = Data()

    /// Without `cleared` (the tests), the clear time lives in memory only.
    init(desk: Desk, devices: Devices, push: Push? = nil, cleared: Cleared? = nil, speech: Speech = Speech()) {
        self.speech = speech
        self.desk = desk
        self.devices = devices
        self.push = push
        self.cleared = cleared ?? Cleared(file: nil)
        sentAccounts = (try? Self.encode(accounts)) ?? Data()
        desk.onJobChange = { [weak self] job in
            self?.send("job", JobJSON(job: job))
            self?.push?.changed()
        }
        desk.onInboxChange = { [weak self] item in self?.send("inbox", InboxJSON(item: item)) }
        desk.onCheckChange = { [weak self] check in self?.send("check", MacCheckJSON(check: check)) }
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
        router.post("v1/jobs") { request, _ in try await self.dispatch(try await Self.decode(DispatchRequest.self, from: request)) }
        router.get("v1/jobs") { request, _ in await self.jobs(limit: request.uri.queryParameters.get("limit", as: Int.self) ?? 50) }
        router.get("v1/jobs/:id") { _, context in try await self.job(context.parameters.require("id")) }
        router.get("v1/jobs/:id/wait") { _, context in try await self.wait(context.parameters.require("id")) }
        router.post("v1/jobs/:id/stop") { _, context in try await self.stop(context.parameters.require("id")) }
        router.post("v1/stop-all") { _, _ in await self.stopAll() }
        router.post("v1/jobs/:id/dismiss") { _, context in try await self.dismiss(context.parameters.require("id")) }
        router.post("v1/jobs/:id/messages") { request, context in
            try await self.message(context.parameters.require("id"), try await Self.decode(NewMessage.self, from: request))
        }
        router.get("v1/jobs/:id/publish") { _, context in try await self.publishAction(context.parameters.require("id")) }
        router.post("v1/jobs/:id/publish") { request, context in
            try await self.publish(context.parameters.require("id"), try await Self.decode(Approval.self, from: request))
        }
        router.post("v1/clear") { _, _ in try await self.clear() }
        router.get("v1/inbox") { _, _ in await self.inbox() }
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
        router.post("v1/checks/:id/result") { request, context in
            try await self.checkResult(context.parameters.require("id"), try await Self.decode(MacCheck.Report.self, from: request))
        }
        router.post("v1/devices") { request, _ in try await self.register(try await Self.decode(NewDevice.self, from: request)) }
        router.post("v1/activities") { request, _ in try await self.activity(try await Self.decode(Push.Token.self, from: request)) }
        router.post("v1/notifications") { request, _ in try await self.notifications(try await Self.decode(NotificationToken.self, from: request)) }
        router.get("v1/settings/models") { _, _ in Self.json(Models.current) }
        router.put("v1/settings/models") { request, _ in try Self.change(try await Self.decode(Models.self, from: request)) }
        router.get("v1/settings/models/options") { _, _ in await Self.options() }
        return router
    }

    // MARK: Endpoints

    func status() -> Response {
        Self.json(Status(runner: .init(version: Self.version, host: ProcessInfo.processInfo.hostName, update: updates?.status),
                         accounts: accounts, models: .current, clearedAt: cleared.at,
                         github: (GitHubApp.inUse ? GitHubActor.app : .owner).rawValue, checks: GitHubApp.checks))
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
    /// the runner's conversation.
    func plan(_ request: PlanRequest) async throws -> Response {
        let words = request.said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return Self.json(PlanAnswer(.none)) }
        let turns = try request.turns.map(Self.turns)
        let said = request.answer.map { Desk.answered(words, question: $0.question, option: $0.option) } ?? words
        return Self.json(PlanAnswer(await desk.converse(said, shown: request.answer?.option, turns: turns)))
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

    func dispatch(_ request: DispatchRequest) throws -> Response {
        do {
            let job = try desk.dispatch(request.job.id, branch: request.job.branch, account: request.job.account,
                                        rounds: request.job.rounds, check: request.job.check, model: request.job.model)
            return Self.json(JobJSON(job: job), status: .created)
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

    /// What only the user can answer and hasn't settled, the longest-waiting first. Items put off
    /// until later are in it too, saying so.
    func inbox() -> Response {
        Self.json(desk.inbox.filter(\.isOpen).map { InboxJSON(item: $0) })
    }

    /// The user settles an inbox item: answers it (the answer goes to its job), marks it done, or
    /// puts it off until later.
    func answer(_ id: String, _ answer: InboxAnswer) throws -> Response {
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
            return Self.json(InboxJSON(item: try desk.settle(id, how)))
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
        let name = mac.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100)) }.flatMap { $0.isEmpty ? nil : $0 } ?? "a Mac"
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
    /// When Clear done was last pressed, or null: the API promises the key either way.
    var clearedAt: Date?
    /// Who the runner's own GitHub calls act as: "app" (Oby by Deskree) or "owner" (the owner's gh login).
    var github: String = GitHubActor.owner.rawValue
    /// Whether Oby's review and Mac check go on pull requests as check runs: "ok", "missing
    /// permission" (the app lacks Checks: write) or "no app" (`GitHubApp.checks`).
    var checks: String = "no app"

    private enum Keys: String, CodingKey { case runner, accounts, models, clearedAt, github, checks }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(runner, forKey: .runner)
        try keys.encode(accounts, forKey: .accounts)
        try keys.encode(models, forKey: .models)
        try keys.encode(clearedAt, forKey: .clearedAt)
        try keys.encode(github, forKey: .github)
        try keys.encode(checks, forKey: .checks)
    }
}

/// What `POST /v1/clear` answers and the `clear` event carries.
struct ClearedJSON: Encodable {
    var clearedAt: Date
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

    private enum Nullable: String, CodingKey { case base, pr, session, started, finished, commits, published, pushed, publishError, summaries, issue, rounds, round, check, model, notes, pullRequest, pullRequestError, dismissed, reviewing, review, reviewError, reviewOf, files, lead, claim, outgoing, question, limit, startCommit, macCheck, mergeError, appleCheck, appleRan, tetrix }

    private enum Derived: String, CodingKey { case pipeline, title, mergeNeedsYou }

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
        if job.macCheck == nil { try nulls.encodeNil(forKey: .macCheck) }
        if job.mergeError == nil { try nulls.encodeNil(forKey: .mergeError) }
        if job.appleCheck == nil { try nulls.encodeNil(forKey: .appleCheck) }
        if job.appleRan == nil { try nulls.encodeNil(forKey: .appleRan) }
        if job.tetrix == nil { try nulls.encodeNil(forKey: .tetrix) }
        // What went out is always a list: empty before anything did.
        if job.outgoing == nil { try nulls.encode([Outgoing](), forKey: .outgoing) }
    }
}

/// A failure record with every key the API promises, null where Swift would leave one out.
struct FailureJSON: Encodable {
    var record: FailureRecord

    private enum Nullable: String, CodingKey { case job, repo, rounds, postMortem, studyError, issue, issueError, fix }
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

/// An inbox item with every key the API promises, and its state: `open`, `later` (put off until
/// a time still to come) or `done`.
struct InboxJSON: Encodable {
    var item: InboxItem

    private enum Keys: String, CodingKey { case id, kind, job, title, text, options, created, done, later, answer, state, outgoing, headline, happened, recommended, why }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(item.id, forKey: .id)
        try keys.encode(item.kind, forKey: .kind)
        try keys.encode(item.job, forKey: .job)
        try keys.encode(item.title, forKey: .title)
        try keys.encode(item.text, forKey: .text)
        try keys.encode(item.options, forKey: .options)
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

struct AccountJSON: Encodable {
    var state: AccountState

    private enum Keys: String, CodingKey { case id, agent, name, label, signedIn, fiveHour, sevenDay, fiveHourResets, sevenDayResets, running, fullUntil, tetrix, tetrixJobs, tetrixUsed }

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
    }
}

/// What `POST /v1/plans` answers: a plan, the brain's question, a reply, or nothing.
struct PlanAnswer: Encodable {
    struct Draft: Encodable {
        var said: String
        var reply: String
        var guessed: Bool
        var job: JobJSON
        /// A stronger model for complex work, or null; the job uses it only if the client asks.
        var suggestedModel: String?

        private enum Keys: String, CodingKey { case said, reply, guessed, job, suggestedModel }

        func encode(to encoder: any Encoder) throws {
            var keys = encoder.container(keyedBy: Keys.self)
            try keys.encode(said, forKey: .said)
            try keys.encode(reply, forKey: .reply)
            try keys.encode(guessed, forKey: .guessed)
            try keys.encode(job, forKey: .job)
            try keys.encode(suggestedModel, forKey: .suggestedModel)
        }
    }

    var kind: String
    /// Every job of the plan.
    var drafts: [Draft]?
    /// The first one, for apps that know only one job per plan.
    var draft: Draft?
    var said: String?
    var question: Plan.Question?
    var text: String?

    @MainActor init(_ talk: Desk.Talk) {
        switch talk {
        case .plan(let list):
            kind = "plan"
            drafts = list.map { Draft(said: $0.said, reply: $0.reply, guessed: $0.guessed, job: JobJSON(job: $0.job), suggestedModel: $0.suggestedModel) }
            draft = drafts?.first
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

/// Only what the user may change on a plan, and the plan's job id; the rest comes from the plan.
struct DispatchRequest: Decodable {
    /// The plan's job as the client sends it back. Rounds and check are optional: an older app
    /// leaves them out and the plan's values stay; `"check": null` clears the check.
    struct Edited: Decodable {
        var id: String
        var branch: String
        var account: String
        var rounds: Int?
        var check: String??
        /// The draft's suggested model to use it, or null to stay on Settings › Models.
        var model: String??

        private enum Keys: String, CodingKey { case id, branch, account, rounds, check, model }

        init(from decoder: any Decoder) throws {
            let keys = try decoder.container(keyedBy: Keys.self)
            id = try keys.decode(String.self, forKey: .id)
            branch = try keys.decode(String.self, forKey: .branch)
            account = try keys.decode(String.self, forKey: .account)
            rounds = try keys.decodeIfPresent(Int.self, forKey: .rounds)
            check = keys.contains(.check) ? .some(try keys.decodeIfPresent(String.self, forKey: .check)) : nil
            model = keys.contains(.model) ? .some(try keys.decodeIfPresent(String.self, forKey: .model)) : nil
        }
    }

    var job: Edited
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

struct NewMessage: Decodable {
    var text: String
}
