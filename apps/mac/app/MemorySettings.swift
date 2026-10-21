import SwiftUI

/// Settings › Memory (docs/onboarding.md section 5; #378): what Oby remembers, about you and per
/// repository, each with where it came from and Delete; "Find what I keep repeating", which reads
/// your conversations and the reviews on recent merged pull requests; and what it found, each a
/// "Can I remember that?" with its quotes and pull requests, Remember or Not this. Nothing is saved
/// without Remember. Sangam's design has no Memory page yet: it's his Settings components, kept
/// plain.
struct MemorySettingsView: View {
    var runner: Runner?
    /// Nil until the runner answered, or when it keeps no memory (the Swift runner).
    @State private var list: RunnerMemoryList?
    @State private var problem: String?
    @State private var finding = false
    /// What the last find read, in a line.
    @State private var looked: String?
    @State private var deleting: RunnerMemory?

    init(runner: Runner?, list: RunnerMemoryList? = nil) {
        self.runner = runner
        _list = State(initialValue: list)
    }

    static let findFooter = "Oby reads what you said in your conversations and what reviewers wrote on recent merged pull requests, and suggests what came up in two places or more. Anything that looks like a secret is left out. Nothing is saved until you say Remember."

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let suggestions = list?.suggestions, !suggestions.isEmpty {
                SetGroup("Can I remember that?") {
                    ForEach(suggestions) { suggestion in row(suggestion) }
                }
            }
            SetGroup(footer: Self.findFooter, problem: problem) {
                SetRow("Find what I keep repeating", about: looked) {
                    if finding { ProgressView().controlSize(.small) }
                    Button(finding ? "Looking…" : "Find") { find() }
                        .buttonStyle(.set)
                        .disabled(finding || runner == nil || list == nil)
                }
            }
            if let list {
                if list.memories.isEmpty {
                    SetGroup("About you") { SetRow("Nothing remembered yet", quiet: true) }
                }
                ForEach(groups(list.memories), id: \.title) { group in
                    SetGroup(group.title) { ForEach(group.memories) { memory in row(memory) } }
                }
            } else {
                SetGroup { SetRow(runner == nil ? "Set the runner's address first." : "This runner has no memory.", quiet: true) }
            }
        }
        .task(id: runner?.base.absoluteString ?? "") { await load() }
        .confirmationDialog("Delete “\(deleting?.title ?? "the memory")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let memory = deleting {
                    deleting = nil
                    act { try await $0.deleteMemory(memory.id) }
                }
            }
        } message: {
            Text("Oby forgets it.")
        }
    }

    /// "About you" first, then one group per repository, as obid lists them.
    func groups(_ memories: [RunnerMemory]) -> [(title: String, memories: [RunnerMemory])] {
        var out: [(title: String, memories: [RunnerMemory])] = []
        for memory in memories {
            let title = memory.repo ?? "About you"
            if let at = out.firstIndex(where: { $0.title == title }) {
                out[at].memories.append(memory)
            } else {
                out.append((title, [memory]))
            }
        }
        return out
    }

    private func row(_ memory: RunnerMemory) -> some View {
        SetRow(about: "\(memory.text)\n\(memory.from)") {
            Text(verbatim: memory.title)
        } control: {
            Button("Delete", role: .destructive) { deleting = memory }
                .buttonStyle(.set)
                .accessibilityLabel("Delete \(memory.title)")
        }
    }

    private func row(_ suggestion: RunnerMemorySuggestion) -> some View {
        SetRow(controlOnTop: true) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: suggestion.title)
                SetAbout("\(suggestion.text)\n\(suggestion.repo.map { "For \($0) · " } ?? "")\(suggestion.from)")
                ForEach(Array(suggestion.sources.enumerated()), id: \.offset) { _, source in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "“\(source.quote)”").font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.item)
                            .fixedSize(horizontal: false, vertical: true)
                        if let link = source.link {
                            Link(source.place, destination: link).font(Tokens.font(Tokens.textSm))
                        } else {
                            SetAbout(source.place)
                        }
                    }
                }
            }
        } control: {
            Button("Not this") { act { try await $0.dismissSuggestion(suggestion.id) } }
                .buttonStyle(.set)
                .accessibilityLabel("Don't remember \(suggestion.title)")
            Button("Remember") { act { _ = try await $0.remember(suggestion.id) } }
                .buttonStyle(.set)
                .accessibilityLabel("Remember \(suggestion.title)")
        }
    }

    private func load() async {
        guard let runner else { return }
        do {
            list = try await runner.memory()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func act(_ work: @escaping (Runner) async throws -> Void) {
        guard let runner else { return }
        Task {
            do {
                try await work(runner)
                problem = nil
            } catch {
                problem = error.localizedDescription
            }
            await load()
        }
    }

    private func find() {
        guard let runner else { return }
        finding = true
        Task {
            do {
                let found = try await runner.findMemories()
                looked = Self.looked(found)
                problem = found.problems.isEmpty ? nil : found.problems.joined(separator: " ")
            } catch {
                problem = error.localizedDescription
            }
            finding = false
            await load()
        }
    }

    /// "Read 40 conversations and 12 pull requests: 3 things came up more than once."
    static func looked(_ found: RunnerMemoryFound) -> String {
        let count = { (n: Int, one: String, many: String) in n == 1 ? "1 \(one)" : "\(n) \(many)" }
        let read = "Read \(count(found.read.conversations, "conversation", "conversations")) and \(count(found.read.pullRequests, "pull request", "pull requests"))"
        switch found.suggestions.count {
        case 0: return "\(read): nothing came up more than once."
        case 1: return "\(read): 1 thing came up more than once."
        case let n: return "\(read): \(n) things came up more than once."
        }
    }
}
