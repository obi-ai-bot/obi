import AppKit
import SwiftUI

/// Say hi in two minutes (F14): hello, hold fn, permissions, agents and accounts, then which
/// models Oby thinks and works with. Every step can be skipped, closing the window skips the
/// rest, and the menu shows it again. Then Oby moves into the notch.
final class FirstLaunch: NSObject, NSWindowDelegate {
    static let doneKey = "firstLaunchDone"
    static var done: Bool { UserDefaults.standard.bool(forKey: doneKey) }

    private let island: IslandController
    private var window: NSWindow?

    init(island: IslandController) { self.island = island }

    func show() {
        NSApp.activate()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = FirstLaunchView(voice: island.model.voice, permissions: Permissions(),
                                   tools: Tools(store: island.desk.accounts),
                                   onDone: { [weak self] in self?.window?.close() })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 580),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }

    /// Finished, skipped or closed: it doesn't come back by itself, and Oby moves into the notch.
    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: Self.doneKey)
        window = nil
        island.open()
    }
}

private struct FirstLaunchView: View {
    enum Step: Int, CaseIterable { case hello, talk, permissions, agents, models }

    let voice: Voice
    let permissions: Permissions
    let tools: Tools
    let onDone: () -> Void

    @State private var step = Step.hello
    /// The last thing you said while trying fn.
    @State private var heard = ""
    @State private var problem: String?
    /// "agent|model"
    @State private var lead = ""
    @State private var routine: [String: String] = [:]
    @State private var complex: [String: String] = [:]
    /// The Lead Oby proposed last: while it's unchanged, Oby may propose another.
    @State private var proposedLead = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case .hello: hello
                case .talk: talk
                case .permissions: permissionsStep
                case .agents: agents
                case .models: models
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(.horizontal, 36)
        .padding(.top, 44)
        .padding(.bottom, 24)
        .frame(width: 640, height: 580)
        // Accessibility has no callback: look again every couple of seconds while the window is up.
        .task {
            while !Task.isCancelled {
                await permissions.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .task(id: step) {
            if step == .agents || step == .models { await tools.refresh() }
            if step == .models { propose() }
        }
        // Back from signing in, in Terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if step == .agents { Task { await tools.refresh() } }
        }
        .onChange(of: voice.words) { _, words in
            if !words.isEmpty { heard = words }
        }
    }

    // MARK: Steps

    private var hello: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(nsImage: .obyMenuBarIcon)
                .resizable().renderingMode(.template).frame(width: 72, height: 72)
                .padding(.bottom, 8)
            title("Hi, I'm Oby.")
            text("I live in the notch and hand your coding work to the tools you already use: Claude Code, Codex and Cursor. They work in their own copies of your repositories, and I tell you when they're done.")
            text("Two minutes and we're set. You can skip any step.")
        }
    }

    private var talk: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Hold fn to talk")
            text("Hold fn (or Control-Option), say hi, and let go. Oby listens only while you hold it. fn + Space keeps listening until you press fn again.")
            if permissions.state(.accessibility) != .allowed {
                permissionRow(.accessibility)
            }
            HStack(spacing: 12) {
                Image(systemName: voice.phase == .listening ? "waveform" : "mic")
                    .font(.system(size: 22)).frame(width: 32)
                    .symbolEffect(.variableColor, isActive: voice.phase == .listening)
                Text(voice.phase == .listening ? (voice.words.isEmpty ? "Listening…" : voice.words)
                     : heard.isEmpty ? "Try it now." : "You said “\(heard)”. Oby answers in the notch.")
                    .font(.system(size: 15, weight: .medium))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            caption("The first time you hold it, macOS asks for the microphone.")
        }
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Permissions")
            text("Each one is asked only when you allow it here or need it, and each is separate: say no to any, and the rest keeps working.")
            ForEach(Permissions.Kind.allCases, id: \.self) { permissionRow($0) }
            caption("Screen Recording isn't asked: nothing in Oby uses it yet.")
        }
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                title("Agents and accounts")
                Spacer()
                if tools.looking { ProgressView().controlSize(.small) }
            }
            text("Oby found these on your Mac. Each signs in through its own login, in Terminal: Oby never sees your password.")
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(Tools.all, id: \.self) { toolRow($0) }
                }
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 12) {
            title("Models")
            if tools.connected.isEmpty {
                text(tools.looking ? "Reading each tool's models…"
                     : "Connect Claude Code, Codex or Cursor first. Until then Oby keeps its defaults, and you can show this again from the menu.")
            } else {
                Text(sentence).font(.system(size: 17, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                if tools.connected == ["cursor"] {
                    Label("With only Cursor, Oby may ask you more often: Cursor can't hold it to a typed plan.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                Form {
                    Section {
                        Picker("Thinks with", selection: $lead) {
                            ForEach(tools.connected, id: \.self) { agent in
                                ForEach(tools.models[agent] ?? [], id: \.id) { model in
                                    Text("\(model.name) · \(Usage.tool(agent))").tag("\(agent)|\(model.id)")
                                }
                            }
                        }
                    } header: {
                        Text("The Lead")
                    } footer: {
                        Text("Plans your requests and reviews each job. Until the Lead arrives, Oby plans with Haiku.")
                    }
                    ForEach(tools.connected, id: \.self) { agent in
                        Section(Usage.tool(agent)) {
                            Picker("Routine jobs", selection: binding($routine, agent)) { choices(agent) }
                            Picker("Complex jobs", selection: binding($complex, agent)) { choices(agent) }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, -20)
                caption("Fable and Astra only if you pick them: they're stronger, and use up a plan's limits fast. Complex jobs use their model only when you turn it on for that job; if it's the routine model, there's nothing to turn on.")
            }
        }
    }

    // MARK: Pieces

    private var footer: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { each in
                    Circle().fill(.white.opacity(each == step ? 0.9 : 0.25)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step != .hello {
                Button("Back") { move(-1) }.buttonStyle(.borderless)
            }
            Button(step == .models ? "Skip and finish" : "Skip") {
                if step == .models { onDone() } else { move(1) }
            }
            .keyboardShortcut(.cancelAction)
            Button(primary) {
                if step == .models {
                    save()
                    onDone()
                } else {
                    move(1)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.top, 16)
    }

    private var primary: String {
        switch step {
        case .hello: "Let's go"
        case .models: tools.connected.isEmpty ? "Finish" : "Keep these"
        default: "Continue"
        }
    }

    private func move(_ by: Int) {
        problem = nil
        step = Step(rawValue: step.rawValue + by) ?? step
    }

    private func permissionRow(_ kind: Permissions.Kind) -> some View {
        let state = permissions.state(kind)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: Permissions.symbol(kind)).font(.system(size: 18)).frame(width: 28).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(Permissions.title(kind)).font(.system(size: 14, weight: .semibold))
                Text(Permissions.reason(kind)).font(.system(size: 12)).foregroundStyle(.secondary)
                if state == .denied {
                    Text(Permissions.without(kind)).font(.system(size: 12)).foregroundStyle(.orange)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            switch state {
            case .allowed:
                Label("Allowed", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
            case .notAsked:
                Button("Allow") { Task { await permissions.ask(kind) } }
            case .denied:
                Button("Open Settings") { Permissions.openSettings(kind) }
            }
        }
        .padding(14)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func toolRow(_ agent: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Usage.symbol(agent)).font(.system(size: 18)).frame(width: 28).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(Usage.tool(agent)).font(.system(size: 14, weight: .semibold))
                ForEach(status(agent), id: \.self) { line in
                    Text(line).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            toolButtons(agent)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    /// What Oby knows about the tool, one line each.
    private func status(_ agent: String) -> [String] {
        let installed = tools.installed[agent] != nil
        switch agent {
        case "gemini":
            return [installed ? "Found. Gemini isn't in Oby's first version." : "Not installed. Gemini isn't in Oby's first version."]
        case "cursor":
            guard installed else { return ["Install the Cursor CLI: `\(Tools.installCursor)`, and Oby finds it."] }
            guard tools.cursorHasACP else { return ["Update the Cursor CLI: `\(Tools.updateCursor)`. Oby needs its `acp` command."] }
            let accounts = tools.accounts("cursor")
            if accounts.isEmpty { return ["Found. Connect an account so Oby can send it jobs."] }
            return accounts.map { "\($0.account.name): \($0.label ?? "signed out")" }
                + (CursorFacts.separateLogins ? [] : [CursorFacts.oneLogin + "."])
        default:
            guard installed else { return ["Not installed. Install \(Usage.tool(agent)), and Oby finds it."] }
            let accounts = tools.accounts(agent)
            if accounts.isEmpty { return ["Found. Connect an account so Oby can send it jobs."] }
            return accounts.map { "\($0.account.name): \($0.label ?? "signed out")" }
        }
    }

    @ViewBuilder
    private func toolButtons(_ agent: String) -> some View {
        if tools.installed[agent] != nil {
            switch agent {
            case "claude", "codex", "cursor":
                let signedOut = tools.accounts(agent).filter { !$0.signedIn }
                if tools.accounts(agent).isEmpty {
                    Button("Connect") { attempt { try tools.connect(agent) } }
                } else if let account = signedOut.first?.account {
                    Button("Sign In") { attempt { try tools.store.signIn(account) } }
                } else {
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(.green)
                }
            default:
                EmptyView()
            }
        }
        // Installing is never automatic: the command is for the user to run.
        if agent == "cursor", tools.installed[agent] == nil || !tools.cursorHasACP {
            Button("Copy Command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tools.installed[agent] == nil ? Tools.installCursor : Tools.updateCursor, forType: .string)
            }
        }
    }

    private func choices(_ agent: String) -> some View {
        ForEach(tools.models[agent] ?? [], id: \.id) { Text($0.name).tag($0.id) }
    }

    private func binding(_ picks: Binding<[String: String]>, _ agent: String) -> Binding<String> {
        Binding { picks.wrappedValue[agent] ?? "" } set: { picks.wrappedValue[agent] = $0 }
    }

    // MARK: Models

    /// "Oby thinks with Sonnet 5.5 and works with Sonnet 5.5 and Opus 5.5." Only the tools Oby
    /// can run jobs on work.
    private var sentence: String {
        let parts = lead.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return "" }
        let thinks = name(parts[1], parts[0])
        let workers = tools.connected.filter { ModelPicks.workers.contains($0) }
        if workers.count == 1, let agent = workers.first {
            let jobs = Set([routine[agent], complex[agent]].compactMap { $0 })
            let works = (tools.models[agent] ?? []).filter { jobs.contains($0.id) }.map(\.name)
            let on = parts[0] == agent ? "" : " on \(Usage.tool(parts[0]))"
            return "Oby thinks with \(thinks)\(on) and works with \(works.joined(separator: " and "))."
        }
        guard !workers.isEmpty else { return "Oby thinks with \(thinks) on \(Usage.tool(parts[0]))." }
        let works = ListFormatter.localizedString(byJoining: workers.map(Usage.tool))
        return "Oby thinks with \(Usage.tool(parts[0])) (\(thinks)) and works with \(works)."
    }

    private func name(_ model: String, _ agent: String) -> String {
        tools.models[agent]?.first { $0.id == model }?.name ?? model
    }

    /// Each time Models opens, fills in the tools with no pick yet: what the user saved (in an
    /// earlier first launch or in Settings) if it's still offered, else a proposal. The Lead is
    /// proposed again while the user hasn't changed it, so a tool connected since can take it.
    private func propose() {
        var lists: [String: [String]] = [:]
        for agent in tools.connected {
            let ids = (tools.models[agent] ?? []).map(\.id)
            lists[agent] = ids
            let saved = { (key: String) in ModelPicks.saved(key).flatMap { ids.contains($0) ? $0 : nil } }
            if routine[agent] == nil { routine[agent] = saved("\(agent).model") ?? ModelPicks.routine(ids) }
            if complex[agent] == nil { complex[agent] = saved("\(agent).complexModel") ?? ModelPicks.complex(ids) }
        }
        guard lead.isEmpty || lead == proposedLead else { return }
        if let agent = ModelPicks.saved("lead.agent"), let model = ModelPicks.saved("lead.model"), lists[agent]?.contains(model) == true {
            lead = "\(agent)|\(model)"
        } else if let pick = ModelPicks.lead(lists) {
            lead = "\(pick.agent)|\(pick.model)"
        }
        proposedLead = lead
    }

    private func save() {
        guard !tools.connected.isEmpty else { return }
        let defaults = UserDefaults.standard
        let parts = lead.split(separator: "|", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            defaults.set(parts[0], forKey: "lead.agent")
            defaults.set(parts[1], forKey: "lead.model")
        }
        for agent in tools.connected {
            guard let model = routine[agent], !model.isEmpty else { continue }
            defaults.set(model, forKey: "\(agent).model")
            // What the screen shows, even when it's the routine model: then the island offers nothing.
            if let stronger = complex[agent], !stronger.isEmpty { defaults.set(stronger, forKey: "\(agent).complexModel") }
        }
    }

    // MARK: Text

    private func title(_ words: String) -> some View {
        Text(words).font(.system(size: 30, weight: .bold))
    }

    private func text(_ words: String) -> some View {
        Text(words).font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func caption(_ words: String) -> some View {
        Text(words).font(.system(size: 12)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
    }

    private func attempt(_ action: () throws -> Void) {
        do {
            try action()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
