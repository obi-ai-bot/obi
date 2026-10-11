import Foundation
import Hummingbird
@testable import ObyEngine

// The runner: Oby's engine as a service on an always-on machine, answering only its owner,
// on 127.0.0.1, where `tailscale serve` publishes it to the tailnet.

// `oby-runner vault …`: the vault from a terminal, then out (Runner/VaultCommand.swift).
if CommandLine.arguments.dropFirst().first == "vault" {
    exit(VaultCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}
// `oby-check apple` in an agent's sandbox: an Apple build and test on the user's Mac (Runner/CheckCommand.swift).
if CommandLine.arguments.dropFirst().first == "check" {
    exit(await CheckCommand.run(Array(CommandLine.arguments.dropFirst(2))))
}

let environment = ProcessInfo.processInfo.environment
guard let owner = environment["OBY_OWNER"], !owner.isEmpty else {
    Logger.runner.error("OBY_OWNER isn't set: it's the owner's Tailscale login, and the runner answers no one else.")
    exit(1)
}
let port = environment["OBY_PORT"].flatMap { Int($0) } ?? 7777
// The Watch API's own port, which a Cloudflare Tunnel publishes (Runner/WatchAPI.swift).
let watchPort = environment["OBY_WATCH_PORT"].flatMap { Int($0) } ?? 7778
// A pipe to an agent that just exited must not take the runner down with it.
signal(SIGPIPE, SIG_IGN)
try FileManager.default.createDirectory(at: Workspace.root, withIntermediateDirectories: true)

// The secret scan learns the vault now, so a vault it can't read shows in the journal at once.
do {
    _ = try Vault.shared.leaks()
} catch {
    Logger.runner.error("vault: \(error.localizedDescription, privacy: .public). Nothing is published until it's fixed.")
}

let speech = Speech()
do { try await speech.discardAbandonedAudio() }
catch {
    Logger.runner.error("Couldn't delete abandoned speech audio; refusing to start.")
    exit(1)
}
let desk = Desk()
desk.issueSync.enabled = true
// Macs that follow the runner take its merge checks (Engine/Checks.swift), and the Apple checks
// agents ask for with `oby-check apple` (Engine/AppleChecks.swift), which runs this executable.
desk.queuesMacChecks = true
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

// systemd stops the runner with SIGTERM: agents end now, and their jobs show as interrupted.
// The sources live as long as the runner.
let stops = [SIGTERM, SIGINT].map { number in
    signal(number, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
    source.setEventHandler {
        MainActor.assumeIsolated { desk.quit() }
        exit(0)
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

// Who is signed in, and the repositories the brain may pick: now, then every five minutes.
Task {
    while true {
        await desk.refresh()
        try? await Task.sleep(for: .seconds(300))
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
let router = api.router(owner: owner)
watchAPI.pairing(on: router)
let app = Application(router: router,
                      configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "oby-runner"))
// Always up, so writing watch.json is enough; without it, it answers 503 to everything.
let watchApp = Application(router: watchAPI.router(),
                           configuration: .init(address: .hostname("127.0.0.1", port: watchPort), serverName: "oby-runner"))
Logger.runner.notice("Oby's runner \(API.version, privacy: .public) in \(Workspace.root.path, privacy: .public), for \(owner, privacy: .public)")
try await withThrowingDiscardingTaskGroup { group in
    group.addTask { try await app.runService(gracefulShutdownSignals: []) }
    group.addTask { try await watchApp.runService(gracefulShutdownSignals: []) }
}
