import Foundation
import Hummingbird
@testable import ObyEngine

// The runner: Oby's engine as a service on an always-on machine, answering only its owner,
// on 127.0.0.1, where `tailscale serve` publishes it to the tailnet. Or on the user's own Mac
// (#283), as the Oby app's login item, answering only that app with a token of its own
// (Engine/LocalRunner.swift): then nothing publishes it, and remote devices come through the gateway.

#if !os(Linux)
// On a Mac, the runner's job files live next to the app's, never in the same folder: the app runs
// its own engine there (Workspace.root). Accounts are shared because Settings signs them in there.
// Before anything reads OBY_HOME.
if ProcessInfo.processInfo.environment["OBY_HOME"]?.isEmpty ?? true {
    setenv("OBY_HOME", LocalRunner.home.path, 1)
}
#endif

// `oby-runner vault …`: the vault from a terminal, then out (Runner/VaultCommand.swift).
if CommandLine.arguments.dropFirst().first == "vault" {
    exit(VaultCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}
// `oby-check apple` in an agent's sandbox: an Apple build and test on the user's Mac (Runner/CheckCommand.swift).
if CommandLine.arguments.dropFirst().first == "check" {
    exit(await CheckCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

let environment = ProcessInfo.processInfo.environment
let port = environment["OBY_PORT"].flatMap { Int($0) } ?? LocalRunner.port
// Who it answers: the owner's Tailscale login (OBY_OWNER), which `tailscale serve` vouches for. On
// a Mac without one, the Oby app on the same Mac, with the runner's own token.
let access: Access
if let owner = environment["OBY_OWNER"], !owner.isEmpty {
    access = .tailnet(owner: owner)
} else {
    #if os(Linux)
    Logger.runner.error("OBY_OWNER isn't set: it's the owner's Tailscale login, and the runner answers no one else.")
    exit(1)
    #else
    do {
        access = .local(token: try LocalRunner.makeToken())
    } catch {
        Logger.runner.error("\(error.localizedDescription, privacy: .public) The runner can't let Oby in without it.")
        exit(1)
    }
    #endif
}
let owner: String = if case .tailnet(let login) = access { login } else { "Oby on this Mac" }
// The Watch API's own port, which a Cloudflare Tunnel publishes (Runner/WatchAPI.swift).
let watchPort = environment["OBY_WATCH_PORT"].flatMap { Int($0) } ?? 7778
// The LAN gateway is the only non-loopback listener. It owns pairing and device-token access.
let gatewayPort = environment["OBY_GATEWAY_PORT"].flatMap { Int($0) } ?? GatewayRoutes.port
// A pipe to an agent that just exited must not take the runner down with it.
signal(SIGPIPE, SIG_IGN)
try FileManager.default.createDirectory(at: Workspace.root, withIntermediateDirectories: true)

// The secret scan learns the vault now, so a vault it can't read shows in the journal at once.
do {
    _ = try Vault.shared.leaks()
} catch {
    Logger.runner.error("vault: \(error.localizedDescription, privacy: .public). Nothing is published until it's fixed.")
}

// The runner's own GitHub calls go as the Oby by Deskree app when it's set up; pushes and pull
// requests stay with the owner's gh login (Engine/GitHubApp.swift).
switch GitHubAppKey.load(environment) {
case .success(let app):
    GitHubApp.shared = app
    Task {
        let accounts = await app.check()
        if app.works {
            Logger.runner.notice("GitHub: as the app \(app.id, privacy: .public), installed for \(accounts.joined(separator: ", "), privacy: .public)")
        } else {
            Logger.runner.error("GitHub: the app \(app.id, privacy: .public) has no installation that works yet: calls go as the owner.")
        }
    }
case .failure(let failure):
    Logger.runner.error("GitHub app: \(failure.message, privacy: .public). Calls go as the owner.")
case nil:
    Logger.runner.notice("GitHub: no app set up (\(GitHubApp.idVariable, privacy: .public)): calls go as the owner.")
}

let speech = Speech()
do { try await speech.discardAbandonedAudio() }
catch {
    Logger.runner.error("Couldn't delete abandoned speech audio; refusing to start.")
    exit(1)
}
do { try await speech.startServers() }
catch { Logger.runner.error("Speech servers unavailable; run setup-whisper.sh and check the models and loopback ports.") }
Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(5))
        await speech.maintainServers()
    }
}
// Jobs that were queued or running when the runner went down carry on (Engine/Restarts.swift).
// The runner for this Mac's app answers with the app's accounts (LocalRunner.accounts).
let isLocal: Bool = if case .local = access { true } else { false }
let desk = Desk(accounts: LocalRunner.accounts(local: isLocal), restarts: Restarts(file: Workspace.root.appending(path: "restarts.json")))
desk.loadSettingOptions = {
    guard let codex = try? await CodexAgent.models(home: nil), !codex.isEmpty else { return nil }
    // Cursor's models, from the first signed-in Cursor account; none until one is.
    let cursorHome = desk.accounts.accounts.first { $0.account.agent == "cursor" && $0.signedIn }?.account.home
    let cursor = desk.accounts.accounts.contains { $0.account.agent == "cursor" && $0.signedIn } ? await CursorModels.list(home: cursorHome).map(\.id) : []
    let models = ["claude": AgentModels.claude.map(\.0), "codex": codex.map(\.id), "cursor": cursor]
    let efforts = ["claude": AgentModels.claudeEfforts, "codex": Array(Set(codex.flatMap(\.efforts))).sorted(), "cursor": [String]()]
    let perModel = ["codex": Dictionary(uniqueKeysWithValues: codex.map { ($0.id, $0.efforts) })]
    return (models, efforts, perModel)
}
desk.issueSync.enabled = true
// Every failure is recorded, studied and acted on (Engine/Failures.swift).
desk.failureLog.enabled = true
// Macs that follow the runner take its merge checks (Engine/Checks.swift), and the Apple checks
// agents ask for with `oby-check apple` (Engine/AppleChecks.swift), which runs this executable.
desk.queuesMacChecks = true
Task {
    await desk.cleanWorktrees()
    while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(3 * 60 * 60)) }
        catch { return }
        await desk.cleanWorktrees()
    }
}
// A plan's job about an issue claims the files the issue names (case 2.1, #209), so jobs on the
// same code know about each other and merge oldest first (#237).
desk.issueFiles = { repo, issue in
    guard let text = try? await Shell.ok(["gh", "issue", "view", "\(issue)", "-R", repo, "--json", "title,body"], as: .app),
          let info = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return nil }
    return Claims.files(issue: info)
}
// Inbox items get a headline in plain words from the brain's cheap model (Engine/Inbox.swift).
desk.rewritesInbox = true
do {
    let executable = URL(filePath: (try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe"))
                         ?? Bundle.main.executablePath ?? CommandLine.arguments[0])
    AppleCheck.installed = try AppleCheck.install(executable: executable, port: port)
} catch {
    Logger.runner.error("oby-check couldn't be installed: \(error.localizedDescription, privacy: .public). Agents can't ask for Apple checks.")
}
// Connected apps: agents call them through the broker, in this process, which holds the logins (Runner/Broker.swift).
let broker = Broker(desk: desk, connections: ConnectionStore(file: Workspace.root.appending(path: "connections.json")),
                    uses: UseLog(file: Vault.folder.appending(path: "uses.jsonl")), base: "http://127.0.0.1:\(port)")
let api = API(desk: desk, devices: Devices(file: Workspace.root.appending(path: "devices.json")),
              push: Push(desk: desk, folder: Workspace.root.appending(path: "apns")),
              cleared: Cleared(file: Workspace.root.appending(path: "cleared.json")), speech: speech, broker: broker)

#if os(Linux)
// The runner deploys itself after merges into dev (Runner/Updates.swift). Not on a Mac: there it's
// part of the app, which Sparkle updates (#282).
let updates = Updates(desk: desk)
api.updates = updates
Task {
    while !Task.isCancelled {
        await updates.poll()
        do { try await Task.sleep(for: .seconds(Updates.interval)) }
        catch { return }
    }
}
Task {
    while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) }
        catch { return }
        updates.deployIfReady()
    }
}
#endif

// systemd (launchd on a Mac) stops the runner with SIGTERM: agents end now, and their jobs carry on when it starts again.
// The sources live as long as the runner.
let stops = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { desk.quit() }
        Task {
            await speech.stopServers()
            exit(0)
        }
    }
    source.resume()
    return source
}

// Published PRs outlive agent jobs. Refresh immediately, then every three minutes.
let pullRequests = PullRequests(desk: desk)
Task {
    while !Task.isCancelled {
        await pullRequests.poll()
        do { try await Task.sleep(for: .seconds(PullRequests.interval)) }
        catch { return }
    }
}

// Persisted audit IDs ensure one daily report, including across runner restarts.
Task {
    while !Task.isCancelled {
        await desk.issueSync.audit()
        try? await Task.sleep(for: .seconds(3600))
    }
}

// What a restart left interrupted, steps past their limit, the brain falling back to rules, and
// the post-mortems still to do: every minute.
Task {
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(60))
        desk.failureLog.sweep()
    }
}

// Accounts the user adds or removes in the app's Settings reach a runner that shares them within seconds.
if isLocal {
    Task {
        while true {
            try? await Task.sleep(for: .seconds(10))
            if desk.accounts.reloadSaved() { await desk.accounts.refresh() }
        }
    }
}

// Who is signed in, and the repositories the brain may pick: now, then every five minutes. After the
// first, jobs the runner went down with carry on: their agents commit as the owner, on known accounts.
Task {
    await desk.refresh()
    desk.resumeAfterRestart()
    while true {
        try? await Task.sleep(for: .seconds(300))
        await desk.refresh()
    }
}
Task {
    while true {
        try? await Task.sleep(for: .seconds(15))
        api.ping()
    }
}

let watchAPI = WatchAPI(api: api, watches: Watches(file: Workspace.root.appending(path: "watches.json")),
                        access: AccessFile(file: Workspace.root.appending(path: "watch.json")))
let router = api.router(access: access)
watchAPI.pairing(on: router)
// 127.0.0.1 only, on either machine: the tailnet reaches it through `tailscale serve`, and a Mac's
// other devices through the gateway, never the runner itself.
let app = Application(router: router,
                      configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "oby-runner"))
// Always up, so writing watch.json is enough; without it, it answers 503 to everything.
let watchApp = Application(router: watchAPI.router(),
                           configuration: .init(address: .hostname("127.0.0.1", port: watchPort), serverName: "oby-runner"))
// The LAN gateway (#284), on a Mac only: the one listener on every interface, for paired phones
// on the local network, forwarding to the loopback API with the runner's own token and
// advertised over Bonjour. A tailnet runner has `tailscale serve` instead and binds nothing else.
let gateway: Gateway? = if case .local(let token) = access {
    Gateway(devices: api.devices, pairing: api.pairing, upstream: URL(string: "http://127.0.0.1:\(port)")!, owner: owner, upstreamToken: token,
            homes: { [desk.accounts.homes.path] + desk.accounts.accounts.compactMap(\.account.home) })
} else {
    nil
}
let gatewayApp = gateway.map {
    Application(router: $0.router(), configuration: .init(address: .hostname("0.0.0.0", port: gatewayPort), serverName: "oby-gateway"))
}
let bonjour = Bonjour()
if gatewayApp != nil { bonjour.start(port: gatewayPort) }
Logger.runner.notice("Oby's runner \(API.version, privacy: .public) in \(Workspace.root.path, privacy: .public), for \(owner, privacy: .public)")
try await withThrowingDiscardingTaskGroup { group in
    group.addTask { try await app.runService(gracefulShutdownSignals: []) }
    group.addTask { try await watchApp.runService(gracefulShutdownSignals: []) }
    if let gatewayApp { group.addTask { try await gatewayApp.runService(gracefulShutdownSignals: []) } }
}
