// The Mac app following a runner, as apps/mac/app/RunnerFeed.swift does it, compiled from the
// app's own client code: tests/mac_app.rs builds this file with apps/shared/Runner.swift,
// apps/shared/Decisions.swift, apps/shared/JobList.swift, apps/shared/Elapsed.swift,
// apps/shared/DeviceKey.swift and Engine/, the files the Oby target compiles them from, and runs
// it against a running obid. Nothing here talks HTTP itself: every request is the app's `Runner`
// (apps/shared/Runner.swift), every answer is read into the app's own types. What it saw goes to
// stdout, one line each; the test reads them.
//
// OBID_URL is the test listener's address; OBID_HOME is its non-secret home path. The app's
// production default is LocalRunner.home. No API token is passed in argv or the environment.

import CryptoKit
import Foundation

func say(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// An endpoint obid may not serve: its status, or what failed.
func answered(_ call: () async throws -> Void) async -> String {
    do {
        try await call()
        return "200"
    } catch let error as RunnerError {
        return error.status.map(String.init) ?? error.message
    } catch {
        return "\(error)"
    }
}

let environment = ProcessInfo.processInfo.environment
// The same discovery as RunnerFeed: a private api-token file, then the legacy keychain.
// The test's empty fallback avoids accessing the person's real keychain.
guard let home = environment["OBID_HOME"],
      let token = LocalRunner.token(home: URL(filePath: home), fallback: MemoryTokens()) else {
    say("token refused")
    exit(1)
}
if environment["OBID_TOKEN_ONLY"] == "1" {
    say("token read")
    exit(0)
}
// RunnerFeed.runner(_:token:local:): the URL, trimmed, with a host, and the token.
guard let url = URL(string: (environment["OBID_URL"] ?? "").trimmingCharacters(in: .whitespaces)), url.host() != nil else {
    say("no url")
    exit(1)
}
let runner = Runner(base: url, token: token)

var following: String?
do {
    // RunnerFeed.run: following first, then fetching.
    for try await event in runner.events() {
        switch event {
        case .connected:
            let status = try await runner.status()
            say("status host=\(status.runner.host) version=\(status.runner.version) accounts=\(status.accounts.map(\.account.id).joined(separator: ",")) clearedAt=\(status.clearedAt.map { _ in "set" } ?? "null") mode=\(status.permissions?.mode ?? "none") cleanup=\(status.cleanup != nil)")
            let (list, extras) = try await runner.jobsWithExtras()
            say("jobs \(list.map { "\($0.id):\($0.status.rawValue):\($0.title ?? "")" }.joined(separator: ","))")
            say("extras \(extras.count)")
            let (items, _) = try await runner.inboxWithWords()
            say("inbox \(items.count)")
            // `try?`: history is an enhancement.
            let history = try? await runner.inboxWithWords(state: "done")
            say("inbox-done \(history.map { String($0.0.count) } ?? "failed")")
            // ConversationModel.reload: the latest page; a runner without the thread answers 404, read as none.
            let turns = try await runner.conversation(before: nil, limit: 50)
            say("conversation \(turns.count)")
            // RunnerFeed.take: a job on screen is fetched by id.
            if let first = list.first {
                let one = try await runner.job(first.id)
                say("job \(one.id) \(one.status.rawValue) heading=\(one.heading)")
            }
            // What RunnerFeed starts once it's live, whose failures it only logs: the Mac's merge
            // checks (MacChecks.look) and its publishing key (MacDevice.register).
            say("checks-next \(await answered { _ = try await runner.nextCheck(mac: "Test Mac") })")
            // A P-256 key as DeviceKey.publicKey() gives it (X9.63), made here: no Secure Enclave.
            let deviceKey = P256.Signing.PrivateKey().publicKey.x963Representation
            say("devices \(await answered { _ = try await runner.register(name: "Test Mac", publicKey: deviceKey) })")
            // Clear done, from the window.
            let cleared = try await runner.clear()
            say("cleared \(cleared.formatted(.iso8601))")
            say("ready")
        case .cleared(let date):
            say("event clear \(date.formatted(.iso8601))")
        case .job(let job, _):
            say("event job \(job.id) \(job.status.rawValue)")
            if following == nil, job.status == .running {
                following = job.id
                // Stop all, from the menu bar (apps/mac/app/ObyController.swift).
                let stopped = try await runner.stopAll()
                say("stop-all \(stopped.stopped) \(stopped.jobs.map(\.id).joined(separator: ","))")
            }
            if job.id == following, job.status == .stopped {
                say("done")
                exit(0)
            }
        case .inbox(let item, _):
            say("event inbox \(item.id)")
        case .accounts(let accounts):
            say("event accounts \(accounts.count)")
        case .check, .turn, .step, .conversation, .delta, .artifact, .routine:
            say("event other")
        case .tetrix(let status):
            say("event tetrix connected=\(status.connected)")
        case .github(let work):
            say("event github \(work.signedIn)")
        }
    }
    say("events ended")
    exit(1)
} catch {
    say("failed \(error)")
    exit(1)
}
