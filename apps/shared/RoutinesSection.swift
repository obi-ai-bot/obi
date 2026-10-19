#if os(iOS) || os(macOS)
import SwiftUI

/// Settings › Routines (#395), on the iPhone and in the Mac's Runner settings alike: every routine
/// obid runs on a schedule, with when, its next run and how the last one went, a switch that
/// pauses and resumes it, Run now, and Delete (asked first). Routines are made by asking Oby;
/// each run is a job on Home, in the Routines group.
struct RoutinesSection: View {
    /// The runner, or nil while none is set.
    var runner: Runner?
    /// Goes up with each `routine` event: the list is read again.
    var changes = 0
    /// Nil until the runner answered, or when it keeps no routines (the Swift runner).
    @State private var routines: [RunnerRoutine]?
    @State private var problem: String?
    @State private var deleting: RunnerRoutine?

    /// `routines`: what to show before the runner answers (a test's, or nothing).
    init(runner: Runner?, changes: Int = 0, routines: [RunnerRoutine]? = nil) {
        self.runner = runner
        self.changes = changes
        _routines = State(initialValue: routines)
    }

    private static let footer = "Ask Oby for one, like “every weekday at 9, review the open pull requests in obi”: it waits for your OK in the inbox. Each run is a job on Home, under Routines, with the same checks as any job."

    var body: some View {
        SetGroup("Routines", footer: Self.footer, problem: problem) {
            if let routines {
                if routines.isEmpty { SetRow("No routines yet", quiet: true) }
                ForEach(routines) { routine in row(routine) }
            } else if runner == nil {
                SetRow("Set the runner's address first.", quiet: true)
            } else {
                SetRow("This runner has no routines.", quiet: true)
            }
        }
        .task(id: [runner?.base.absoluteString ?? "", String(changes)]) { await load() }
        .confirmationDialog("Delete \(deleting?.name ?? "the routine")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let routine = deleting { delete(routine) } }
        } message: {
            Text("It won't run again. The jobs it started stay.")
        }
    }

    private func row(_ routine: RunnerRoutine) -> some View {
        SetRow(routine.name, about: routine.about()) {
            HStack(spacing: 8) {
                Button("Run now") { run(routine) }
                    .buttonStyle(.set)
                    .accessibilityLabel("Run \(routine.name) now")
                Button("Delete", role: .destructive) { deleting = routine }
                    .buttonStyle(.set)
                    .accessibilityLabel("Delete \(routine.name)")
                Toggle(routine.name, isOn: Binding(get: { routine.enabled }, set: { setEnabled(routine, $0) }))
                    .toggleStyle(.set)
                    .labelsHidden()
                    .accessibilityLabel(routine.enabled ? "Pause \(routine.name)" : "Resume \(routine.name)")
            }
        }
    }

    private func load() async {
        guard let runner else { return }
        do {
            routines = try await runner.routines()
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

    private func setEnabled(_ routine: RunnerRoutine, _ enabled: Bool) {
        // The switch moves at once; the runner's answer (or the reload after a failure) settles it.
        routines = routines?.map { $0.id == routine.id ? with($0) { $0.enabled = enabled } : $0 }
        act { _ = try await $0.setRoutine(routine.id, enabled: enabled) }
    }

    private func run(_ routine: RunnerRoutine) { act { try await $0.runRoutine(routine.id) } }

    private func delete(_ routine: RunnerRoutine) {
        deleting = nil
        act { try await $0.deleteRoutine(routine.id) }
    }

    private func with(_ routine: RunnerRoutine, _ change: (inout RunnerRoutine) -> Void) -> RunnerRoutine {
        var routine = routine
        change(&routine)
        return routine
    }
}

/// A routine waiting for its next run, on Home's Routines page (Sangam's tasks.ts: "Starts
/// Monday at 9"): its name, where and when it runs, and when it starts next, marked Queued.
struct UpcomingRoutineCard: View {
    let routine: RunnerRoutine

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: routine.name).font(Tokens.font(Tokens.textLg, .semibold)).foregroundStyle(Tokens.ink).lineLimit(2)
                Spacer(minLength: 8)
                WorkMarkView(mark: .queued)
            }
            Text(verbatim: "\(routine.repoName) · \(routine.when)").font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted).lineLimit(1)
            if let starts = routine.starts() {
                Text(verbatim: starts).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: Tokens.cardRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
#endif
