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
    let devices: Devices
    /// Push to the iPhone (Live Activity and alerts), or nil when this runner has none.
    let push: Push?
    /// Everyone following `GET /v1/events`.
    private var streams: [UUID: AsyncStream<String>.Continuation] = [:]
    /// The accounts as last sent, so an unchanged list isn't sent again.
    private var sentAccounts = Data()

    init(desk: Desk, devices: Devices, push: Push? = nil) {
        self.desk = desk
        self.devices = devices
        self.push = push
        sentAccounts = (try? Self.encode(accounts)) ?? Data()
        desk.onJobChange = { [weak self] job in
            self?.send("job", JobJSON(job: job))
            self?.push?.changed()
        }
        watchAccounts()
    }

    /// Every endpoint, behind the owner check.
    nonisolated func router(owner: String) -> Router<BasicRequestContext> {
        let router = Router()
        router.add(middleware: Gate(owner: owner))
        router.get("v1/status") { _, _ in await self.status() }
        router.post("v1/plans") { request, _ in await self.plan(try await Self.decode(PlanRequest.self, from: request)) }
        router.post("v1/jobs") { request, _ in try await self.dispatch(try await Self.decode(DispatchRequest.self, from: request)) }
        router.get("v1/jobs") { request, _ in await self.jobs(limit: request.uri.queryParameters.get("limit", as: Int.self) ?? 50) }
        router.get("v1/jobs/:id") { _, context in try await self.job(context.parameters.require("id")) }
        router.get("v1/jobs/:id/wait") { _, context in try await self.wait(context.parameters.require("id")) }
        router.post("v1/jobs/:id/stop") { _, context in try await self.stop(context.parameters.require("id")) }
        router.post("v1/jobs/:id/messages") { request, context in
            try await self.message(context.parameters.require("id"), try await Self.decode(NewMessage.self, from: request))
        }
        router.get("v1/jobs/:id/publish") { _, context in try await self.publishAction(context.parameters.require("id")) }
        router.post("v1/jobs/:id/publish") { request, context in
            try await self.publish(context.parameters.require("id"), try await Self.decode(Approval.self, from: request))
        }
        router.get("v1/events") { _, _ in await self.events() }
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
        Self.json(Status(runner: .init(version: Self.version, host: ProcessInfo.processInfo.hostName),
                         accounts: accounts, models: .current))
    }

    func plan(_ request: PlanRequest) async -> Response {
        let words = request.said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return Self.json(PlanAnswer(.none)) }
        let said = request.answer.map { Desk.answered(words, question: $0.question, option: $0.option) } ?? words
        return Self.json(PlanAnswer(await desk.plan(said)))
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

    func publishAction(_ id: String) throws -> Response {
        let (job, base) = try publishable(id)
        return Self.json(["action": Publish.action(for: job, base: base), "base": base])
    }

    /// Publishes once a registered phone signed the runner's own sentence for it, and lets only
    /// that sentence through to Publish.
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
        guard token.kind != "alert" else { throw APIError(.unprocessableContent, "kind is update or start.") }
        guard let push else { return Self.json(["push": false]) }
        return Self.json(["push": try push.register(token)])
    }

    /// The app's device token, for alerts when a job needs the user. `push` says whether the runner will push.
    func notifications(_ token: NotificationToken) throws -> Response {
        guard let push else { return Self.json(["push": false]) }
        return Self.json(["push": try push.register(Push.Token(token: token.token, kind: "alert", topic: token.topic, environment: token.environment))])
    }

    func events() -> Response {
        let (stream, continuation) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .bufferingNewest(256))
        let id = UUID()
        streams[id] = continuation
        continuation.onTermination = { _ in Task { @MainActor in self.streams[id] = nil } }
        // Something right away, so proxies pass the headers on.
        continuation.yield(": ping\n\n")
        return Response(status: .ok, headers: [.contentType: "text/event-stream", .cacheControl: "no-cache"],
                        body: ResponseBody { writer in
                            for await event in stream { try await writer.write(ByteBuffer(string: event)) }
                            try await writer.finish(nil)
                        })
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

    private func publishable(_ id: String) throws -> (Job, String) {
        let job = try known(id)
        guard job.canPublish, let base = job.base else {
            throw APIError(.conflict, job.published != nil ? "It's already published." :
                           job.status != .done ? "Nothing to publish: the job hasn't finished." : "Nothing to publish: the job made no commits.")
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

    /// The API's JSON: camelCase as Swift spells it, and ISO 8601 dates.
    nonisolated static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    nonisolated static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) -> Response {
        let data = (try? encode(value)) ?? Data(#"{"error":"The runner couldn't write its answer."}"#.utf8)
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
            guard request.headers[values: .tailscaleUserLogin] == [owner] else {
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
    }

    var runner: Runner
    var accounts: [AccountJSON]
    var models: Models
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

/// A job with every key the API promises, null where Swift would leave one out.
struct JobJSON: Encodable {
    var job: Job

    private enum Nullable: String, CodingKey { case base, pr, session, started, finished, commits, published, issue, rounds, round, check, model, notes }

    func encode(to encoder: any Encoder) throws {
        try job.encode(to: encoder)
        var nulls = encoder.container(keyedBy: Nullable.self)
        if job.base == nil { try nulls.encodeNil(forKey: .base) }
        if job.pr == nil { try nulls.encodeNil(forKey: .pr) }
        if job.session == nil { try nulls.encodeNil(forKey: .session) }
        if job.started == nil { try nulls.encodeNil(forKey: .started) }
        if job.finished == nil { try nulls.encodeNil(forKey: .finished) }
        if job.commits == nil { try nulls.encodeNil(forKey: .commits) }
        if job.published == nil { try nulls.encodeNil(forKey: .published) }
        if job.issue == nil { try nulls.encodeNil(forKey: .issue) }
        // Rounds always has a value in the API: 1 when the job doesn't loop.
        try nulls.encode(job.maxRounds, forKey: .rounds)
        try nulls.encode(job.currentRound, forKey: .round)
        if job.check == nil { try nulls.encodeNil(forKey: .check) }
        if job.model == nil { try nulls.encodeNil(forKey: .model) }
        if job.notes == nil { try nulls.encodeNil(forKey: .notes) }
    }
}

struct AccountJSON: Encodable {
    var state: AccountState

    private enum Keys: String, CodingKey { case id, agent, name, label, signedIn, fiveHour, sevenDay, running }

    func encode(to encoder: any Encoder) throws {
        var keys = encoder.container(keyedBy: Keys.self)
        try keys.encode(state.account.id, forKey: .id)
        try keys.encode(state.account.agent, forKey: .agent)
        try keys.encode(state.account.name, forKey: .name)
        try keys.encode(state.label, forKey: .label)
        try keys.encode(state.signedIn, forKey: .signedIn)
        try keys.encode(state.fiveHour, forKey: .fiveHour)
        try keys.encode(state.sevenDay, forKey: .sevenDay)
        try keys.encode(state.running, forKey: .running)
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

    var said: String
    var answer: Answer?
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
