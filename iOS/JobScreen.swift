import SwiftUI

/// One job in full: what it's doing or how it ended, where it lives, and Publish.
struct JobScreen: View {
    @Environment(Phone.self) private var phone
    @Environment(\.openURL) private var openURL
    let id: String
    @State private var action: String?
    @State private var busy = false
    @State private var problem: String?
    @State private var note = ""
    @State private var telling = false
    @State private var noteProblem: String?

    private var job: Job? { phone.jobs.first { $0.id == id } }

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(job.title).font(.title2.weight(.semibold))
                        HStack(spacing: 8) {
                            StatusPill(status: job.status)
                            Text("\(job.agentName) · \(phone.accounts.first { $0.id == job.account }?.name ?? job.account)")
                                .font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                        if !job.extras.isEmpty {
                            Text(job.extras).font(.footnote).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if job.isActive, !job.step.isEmpty {
                        Label(job.step, systemImage: "gearshape.2").font(.subheadline)
                    }
                    if !job.summary.isEmpty {
                        Text(job.summary).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                    if let notes = job.notes, !notes.isEmpty { told(notes) }
                    // A finished job with a session picks it up again; one that never started can't.
                    if job.status == .running || (!job.isActive && job.session != nil) { talk(job) }
                    details(job)
                    if let problem {
                        Text(problem).font(.footnote).foregroundStyle(.red)
                    }
                    actions(job)
                }
                .padding(16)
            } else {
                ContentUnavailableView("This job isn't on the runner any more.", systemImage: "questionmark.folder")
            }
        }
        .background(Color.black)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// What the user told the agent, oldest first.
    private func told(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("You told the agent").font(.footnote).foregroundStyle(.white.opacity(0.55))
            ForEach(notes.indices, id: \.self) { index in
                Label(notes[index], systemImage: "text.bubble").font(.footnote).lineLimit(3)
            }
        }
    }

    /// One message for the agent, and why it didn't go if it didn't.
    private func talk(_ job: Job) -> some View {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let ready = (1...2000).contains(text.count) && !telling
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Tell the agent…", text: $note, axis: .vertical)
                    .lineLimit(1...5)
                Button { send(text, to: job.id) } label: {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.black)
                        .frame(width: 34, height: 34)
                        .background(.white.opacity(ready ? 1 : 0.4), in: Circle())
                }
                .disabled(!ready)
                .accessibilityLabel("Send to the agent")
            }
            .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 7)
            .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            if let noteProblem {
                Text(noteProblem).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    private func send(_ text: String, to id: String) {
        telling = true
        Task {
            defer { telling = false }
            do {
                try await phone.tell(id, text)
                note = ""
                noteProblem = nil
            } catch {
                noteProblem = error.localizedDescription
            }
        }
    }

    private func details(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Repository", job.repo)
            row("Branch", job.branch, mono: true)
            if let base = job.base { row("Started from", base, mono: true) }
            if let commits = job.commits { row("Commits", commits == 0 ? "None" : "\(commits)") }
            Text("You asked: \(job.request)").font(.footnote).foregroundStyle(.white.opacity(0.55))
        }
    }

    private func row(_ label: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(label).font(.footnote).foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(value).font(mono ? .footnote.monospaced() : .footnote).lineLimit(1)
        }
    }

    @ViewBuilder private func actions(_ job: Job) -> some View {
        if job.isActive {
            wide("Stop", filled: false) { await run { try await phone.stop(job.id) } }
        }
        if let link = job.published.flatMap(URL.init(string:)) {
            wide("Open the draft pull request", filled: true) { openURL(link) }
        } else if job.canPublish {
            if let action {
                VStack(alignment: .leading, spacing: 10) {
                    Text(action).font(.subheadline.weight(.medium))
                    wide(busy ? "Publishing…" : "Publish with Face ID", filled: true, icon: "faceid") {
                        await run {
                            let url = try await phone.publish(job.id, action: action)
                            self.action = nil
                            openURL(url)
                        }
                    }
                    wide("Not now", filled: false) { self.action = nil }
                }
                .padding(14)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                wide("Publish…", filled: true) { await run { action = try await phone.publishAction(job.id) } }
            }
        }
    }

    private func wide(_ title: String, filled: Bool, icon: String? = nil, perform: @escaping () async -> Void) -> some View {
        Button { Task { await perform() } } label: {
            Label { Text(title) } icon: { if let icon { Image(systemName: icon) } }
                .font(.headline)
                .foregroundStyle(filled ? .black : .white)
                .frame(maxWidth: .infinity).frame(height: 48)
                .background(filled ? AnyShapeStyle(.white) : AnyShapeStyle(.white.opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    private func run(_ work: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do {
            try await work()
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }
}
