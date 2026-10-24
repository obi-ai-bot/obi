import SwiftUI

// The job page's pieces (Alternative B, timeline first, obi-ai-bot/obi#739), drawn the same on the
// Mac and the iPhone from the canvas's job.css: the time track, the stages as the page's spine with
// the tool counts, groups and live tool under Work, the check's commands under Check and the secret
// scan under Publish, the usage line, the pull request, and the raw session. A part whose facts
// obid doesn't serve yet isn't drawn. Not on the Watch.

extension Job {
    /// Its stages, from the runner's pipeline (Engine's on the Mac).
    var pageStages: [JobStage] {
        #if os(macOS)
        pipeline.stages
        #else
        pipeline?.stages ?? []
        #endif
    }

    /// Its pull request as the page words it: "Merged", "Approved", "Waiting for review"…
    var pullRequestWords: String? {
        guard published != nil else { return nil }
        #if os(macOS)
        let review = pullRequest?.reviewDecision?.rawValue
        #else
        let review = pullRequest?.reviewDecision
        #endif
        switch (pullRequestState, review) {
        case ("MERGED", _): return "Merged"
        case ("CLOSED", _): return "Closed"
        case (_, "APPROVED"): return "Approved"
        case (_, "CHANGES_REQUESTED"): return "Changes requested"
        default: return "Waiting for review"
        }
    }
}

extension JobStage {
    /// Its id as obid names it: "prepare", "work", "check", "publish", "review"…
    var key: String {
        #if os(macOS)
        id.rawValue
        #else
        id
        #endif
    }
}

extension JobClock {
    /// The job's clock now: paused while it waits on you, planning while it plans in Plan mode.
    static func of(_ job: Job, facts: JobFacts?, mode: String?, needs: Bool, now: Date) -> JobClock {
        let phase: Phase = switch job.status {
        case .done: .done
        case .failed, .stopped, .interrupted: .ended
        case .queued, .running: needs ? .paused : mode == "plan" ? .planning : .working
        }
        let worked = (job.finished ?? now).timeIntervalSince(job.started ?? job.created) - (facts?.waited ?? 0)
        return JobClock(phase: phase, elapsed: max(0, worked), estimate: facts?.estimate)
    }
}

/// One part of the task's card (Sangam's `Section`): its name small at the top, a note or a link at
/// its right, a line above it unless it's the first.
struct PageSection<Content: View, Accessory: View>: View {
    let title: String
    var aside: String? = nil
    var first = false
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.label)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let aside { Text(aside).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted) }
                accessory()
            }
            .padding(.bottom, 16)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16).padding(.bottom, 18)
        .overlay(alignment: .top) { if !first { Tokens.divider.frame(height: 1) } }
    }
}

extension PageSection where Accessory == EmptyView {
    init(_ title: String, aside: String? = nil, first: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, aside: aside, first: first, accessory: { EmptyView() }, content: content)
    }
}

/// A link at a section's right: "Full session ›".
struct SectionLink: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Text(title)
                Image(systemName: "chevron.right").font(Tokens.font(9, .semibold))
            }
            .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.text).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The time track (`.tt`): what's gone filled, a tick for now, and the finish as a range, never
/// one number; orange while paused on you, the range faint across it while it's too early to say.
struct TimeTrack: View {
    let track: JobClock.Track

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Tokens.meter)
                Capsule().fill(Tokens.check).opacity(track.unknown ? 0.25 : 0.45)
                    .frame(width: track.unknown ? width : max(4, (track.rangeEnd - track.rangeStart) * width))
                    .offset(x: track.unknown ? 0 : track.rangeStart * width)
                Capsule().fill(track.paused ? Tokens.needs : Tokens.stageDone).frame(width: max(0, track.done * width))
                RoundedRectangle(cornerRadius: 1).fill(track.paused ? Tokens.needs : Tokens.ink)
                    .frame(width: 2, height: 12).offset(x: track.done * width - 1)
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Time so far and the expected finish")
    }
}

/// The basis line under the track (`.tl-basis`): where the estimate comes from, with an ⓘ.
struct BasisLine: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "info.circle").font(Tokens.font(11))
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
    }
}

/// A stage's, a group's or a check's mark: a green check once done, the working dot pulsing (still
/// with Reduce Motion), orange while it needs you, a ring to come, a dash skipped, red failed.
struct TimelineMark: View {
    let mark: TaskFacts.Mark
    var size: CGFloat = 10

    var body: some View {
        Group {
            switch mark {
            case .done:
                Image(systemName: "checkmark").font(Tokens.font(size * 0.8, .heavy)).foregroundStyle(Tokens.bg)
                    .frame(width: size + 4, height: size + 4).background(Tokens.done, in: Circle())
            case .current: WorkMarkView(mark: .working, dot: size)
            case .needs: Circle().fill(Tokens.needs).frame(width: size, height: size)
            case .upcoming: Circle().strokeBorder(Tokens.check, lineWidth: 1.5).frame(width: size, height: size)
            case .skipped: Capsule().fill(Tokens.check).frame(width: size, height: 2)
            case .failed: Circle().fill(Tokens.danger).frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Round 2-point dots, 6 apart, down to the next stage.
struct DottedLine: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                var y: CGFloat = 1
                while y < geometry.size.height { path.addEllipse(in: CGRect(x: 0, y: y - 1, width: 2, height: 2)); y += 6 }
            }
            .fill(Tokens.check)
        }
    }
}

/// The tool counts as chips (`.count`): wrapping on the Mac, one row that scrolls on the iPhone.
struct CountChips: View {
    let counts: ToolCounts
    var scrolls = false

    var body: some View {
        let chips = counts.chips
        if scrolls {
            ScrollView(.horizontal) { HStack(spacing: 6) { chipViews(chips) } }
                .scrollIndicators(.never)
                .accessibilityLabel(counts.line ?? "")
        } else {
            CenteredFlow(spacing: 6, centred: false) { chipViews(chips) }
                .accessibilityElement(children: .combine)
        }
    }

    private func chipViews(_ chips: [(count: Int, label: String)]) -> some View {
        ForEach(chips, id: \.label) { chip in
            (Text("\(chip.count)").foregroundStyle(Tokens.ink).fontWeight(.medium) + Text(" \(chip.label)").foregroundStyle(Tokens.text))
                .font(Tokens.font(Tokens.textSm)).monospacedDigit()
                .padding(.leading, 9).padding(.trailing, 11).frame(height: 28)
                .background(Tokens.pill, in: Capsule())
                .fixedSize()
        }
    }
}

/// The work in a few plain groups (`.groups`): each a line with its time; the running one open,
/// with what it touched and its tool lines. On the iPhone, only the open one.
struct ActivityGroups: View {
    let groups: [ActivityGroup]
    let now: Date
    var compact = false

    var body: some View {
        let shown = compact ? groups.filter(\.running) : groups
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { group in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center, spacing: 10) {
                        TimelineMark(mark: group.running ? .current : group.failed ? .failed : .done, size: 8).frame(width: 12, height: 12)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.title).font(Tokens.font(Tokens.textBase)).foregroundStyle(group.running ? Tokens.ink : Tokens.item).fadeOut()
                            if group.running, let meta = meta(group) { meta.font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        if let time = time(group) { Text(time).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted) }
                    }
                    if group.running, let tools = group.tools, !tools.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array((compact ? tools.filter(\.running) : tools).enumerated()), id: \.offset) { _, tool in
                                ToolRow(tool: tool, now: now)
                            }
                        }
                        .padding(.leading, 22).padding(.top, 8)
                    }
                }
                .padding(.top, 10).padding(.bottom, group.id == shown.last?.id ? 0 : 9)
                .overlay(alignment: .top) { Tokens.divider.frame(height: 1) }
                .accessibilityElement(children: .combine)
                .accessibilityValue(group.running ? "Working" : group.failed ? "Failed" : "Done")
            }
        }
    }

    /// "2 commands so far · after editing jobs.rs, publish_api.rs +34 −9".
    private func meta(_ group: ActivityGroup) -> Text? {
        var parts: [String] = []
        if let line = group.counts?.line { parts.append(line + " so far") }
        if let files = group.files, !files.isEmpty {
            parts.append(files.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (files.count > 2 ? " and \(files.count - 2) more" : ""))
        }
        let diff = group.diff.flatMap { $0.added == nil && $0.removed == nil ? nil : $0 }
        guard !parts.isEmpty || diff != nil else { return nil }
        var text = Text(parts.joined(separator: " · "))
        if let diff {
            text = text + Text(parts.isEmpty ? "" : " ")
                + Text(diff.added.map { "+\($0)" } ?? "").foregroundStyle(Tokens.done)
                + Text(diff.removed.map { " −\($0)" } ?? "").foregroundStyle(Tokens.danger)
        }
        return text
    }

    private func time(_ group: ActivityGroup) -> String? {
        guard let started = group.started else { return nil }
        return JobPageText.seconds((group.finished ?? now).timeIntervalSince(started))
    }
}

/// One tool call (`.tool-line`): its mark, what it does (the verb sweeping while it runs), its time.
struct ToolRow: View {
    let tool: JobTool
    let now: Date

    var body: some View {
        HStack(spacing: 8) {
            TimelineMark(mark: tool.running ? .current : tool.failed ? .failed : .done, size: 8).frame(width: 12, height: 12)
            Group {
                if tool.running { Sheen(text: tool.summary, size: Tokens.textMd).lineLimit(1) } else {
                    Text(tool.summary).font(Tokens.font(Tokens.textMd)).foregroundStyle(tool.failed ? Tokens.danger : Tokens.muted).fadeOut()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let time { Text(time).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted) }
        }
        .accessibilityElement(children: .combine)
    }

    private var time: String? {
        if tool.running, let started = tool.started { return JobPageText.seconds(now.timeIntervalSince(started)) }
        return tool.seconds.map(JobPageText.seconds)
    }
}

/// The check's commands (`.checks`): each with its mark, the command, what it came to (a small bar
/// of its tests while they run) and how long it took.
struct CheckRows: View {
    let steps: [CheckStep]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                let failed = step.passed == false
                HStack(spacing: 8) {
                    TimelineMark(mark: step.running == true ? .current : failed ? .failed : step.passed == true ? .done : .upcoming, size: 8)
                        .frame(width: 12, height: 16)
                    Text(step.command).font(Tokens.mono(12)).foregroundStyle(failed ? Tokens.danger : Tokens.item).lineLimit(1)
                        .truncationMode(.middle).layoutPriority(1)
                    if let progress = step.progress {
                        Capsule().fill(Tokens.meter).frame(width: 64, height: 4)
                            .overlay(alignment: .leading) { Capsule().fill(Tokens.stageDone).frame(width: 64 * progress) }
                    }
                    if let result = step.result, !(compact && step.progress != nil) {
                        Text(result).font(Tokens.font(Tokens.textSm)).foregroundStyle(failed ? Tokens.danger : Tokens.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let seconds = step.seconds {
                        Text(JobPageText.seconds(seconds)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// A row under Publish: a mark, what happened, a note and its time.
struct FactRow: View {
    let mark: TaskFacts.Mark
    let text: String
    var note: String? = nil
    var time: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            TimelineMark(mark: mark, size: 8).frame(width: 12, height: 16)
            Text(text).font(Tokens.font(Tokens.textMd)).foregroundStyle(mark == .failed ? Tokens.danger : Tokens.text)
                .fixedSize(horizontal: false, vertical: true)
            if let note { Text(note).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted).lineLimit(1) }
            Spacer(minLength: 0)
            if let time { Text(time).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted) }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The box a stage's details sit in (`.tl-inner`).
struct StageBox<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Tokens.cardFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Tokens.line, lineWidth: 1))
            .padding(.top, 10)
    }
}

/// The Timeline (Sangam's #741; "Stages", as before, while obid serves no times): the time track
/// and its basis, then the stages as the page's spine, each with its time, its line, and what
/// hangs off it.
struct JobTimeline: View {
    let job: Job
    let facts: JobFacts?
    /// Its mode ("plan" while it plans), as the runner says it.
    let mode: String?
    /// It waits on you (a question, a plan, a permission): its clock is paused.
    let needs: Bool
    var compact = false
    /// Opens the raw session; nil where there's none.
    var onSession: (() -> Void)? = nil

    /// The first section on the card: no line above it.
    var first = false

    /// Whether obid serves the job's times: the section is the Timeline then, else the Stages as before.
    private var timed: Bool { facts?.estimate != nil || !(facts?.stages.isEmpty ?? true) }

    var body: some View {
        // Ticks once a second only while the job is active.
        TimelineView(.animation(minimumInterval: 1, paused: !job.isActive)) { context in
            let clock = JobClock.of(job, facts: facts, mode: mode, needs: needs, now: context.date)
            let basis = clock.phase == .done ? nil : facts?.estimate?.basis
            PageSection(timed ? "Timeline" : "Stages", aside: timed ? aside(clock) : nil, first: first) {
                if let track = clock.track { TimeTrack(track: track) }
                if let basis { BasisLine(text: basis).padding(.top, clock.track == nil ? 0 : 8) }
                let stages = job.pageStages
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(stages.enumerated()), id: \.element.id) { index, stage in
                        row(stage, last: index == stages.count - 1, now: context.date)
                    }
                }
                .padding(.top, clock.track != nil || basis != nil ? 18 : 0)
            }
        }
    }

    /// Done, how long it took against its estimate (Sangam's #741); before that, where it stands.
    private func aside(_ clock: JobClock) -> String? {
        if clock.phase == .done { return compact ? clock.took.replacingOccurrences(of: "estimated", with: "est.") : clock.took }
        return clock.aside(compact: compact)
    }

    private func mark(_ stage: JobStage) -> TaskFacts.Mark {
        TaskFacts.mark(stage.state, needs: needs, working: job.status == .running)
    }

    private func row(_ stage: JobStage, last: Bool, now: Date) -> some View {
        let mark = mark(stage)
        let timing = facts?.stages[stage.key]
        return HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                TimelineMark(mark: mark).frame(width: 16, height: 18)
                if !last { DottedLine().frame(width: 2).frame(minHeight: 20).padding(.top, 4).padding(.bottom, 2) }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if mark == .current { Sheen(text: stage.title, size: Tokens.textBase) } else {
                        Text(stage.title).font(Tokens.font(Tokens.textBase, .medium))
                            .foregroundStyle(mark == .failed ? Tokens.danger : mark == .upcoming || mark == .skipped ? Tokens.text : Tokens.ink)
                    }
                    Spacer(minLength: 8)
                    if let time = duration(stage, mark: mark, timing: timing, now: now) {
                        Text(time).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                    }
                }
                // The live step under the stage it's on while the agent works (Sangam's
                // `tc-stage-step`), unless the stage's own line already says it.
                if mark == .current, job.status == .running, !job.step.isEmpty, !(stage.detail ?? "").contains(job.step) {
                    Sheen(text: job.step, size: Tokens.textBase).padding(.top, 2)
                }
                // Merged waits on the owner ("Merge it on GitHub"): its line opens the pull request.
                if stage.key == "merged", mark == .current, let url = PublishedLink.url(job.published) {
                    Link(stage.detail ?? "Merge it on GitHub", destination: url).font(Tokens.font(Tokens.textBase, .medium))
                        .foregroundStyle(Tokens.text).padding(.top, 2)
                } else if let detail = detail(stage, mark: mark) {
                    detail.font(Tokens.font(Tokens.textBase)).foregroundStyle(Tokens.muted).padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let sub = sub(stage, mark: mark) {
                    Text(sub).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).lineSpacing(3).padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // Not when it's the job's summary, which the failed card already says.
                if let reason = stage.reason, mark == .failed,
                   job.summary.isEmpty || !(job.summary.hasPrefix(reason) || reason.hasPrefix(job.summary)) {
                    Text(reason).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.danger).padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                inner(stage, mark: mark, now: now)
            }
            .padding(.bottom, last ? 0 : 18)
        }
        .accessibilityElement(children: .contain)
    }

    /// "18s" done, "9m so far" under way, "4m · paused" on you, "≈ 3m" to come.
    private func duration(_ stage: JobStage, mark: TaskFacts.Mark, timing: StageTiming?, now: Date) -> String? {
        guard let timing else { return nil }
        let waited = timing.waited ?? 0
        switch mark {
        case .done, .failed:
            guard let started = timing.started, let finished = timing.finished else { return nil }
            return JobPageText.seconds(finished.timeIntervalSince(started) - waited)
        case .current, .needs:
            guard let started = timing.started else { return nil }
            let so = JobPageText.seconds(now.timeIntervalSince(started) - waited)
            if mark == .needs { return compact ? so : "\(so) · paused" }
            return compact ? so : "\(so) so far"
        case .upcoming:
            if let started = timing.started, job.status == .done { return JobPageText.seconds(now.timeIntervalSince(started)) + (compact ? "" : " so far") }
            return timing.estimate.map { "≈ " + JobPageText.seconds(($0.low + $0.high) / 2) }
        case .skipped:
            return nil
        }
    }

    /// The stage's line: the runner's, with what Work left behind once it's done ("2 commits ·
    /// 3 files +41 −11"), and what didn't happen once a stage before it failed.
    private func detail(_ stage: JobStage, mark: TaskFacts.Mark) -> Text? {
        if mark == .skipped {
            if stage.key == "publish", job.outgoing?.isEmpty ?? true {
                return Text(facts?.scan?.ran == false ? "Nothing went out · the secret scan didn't run, since checks come first" : "Nothing went out")
            }
            if stage.key == "review", job.published == nil { return Text("No pull request to review") }
        }
        // On the iPhone, upcoming stages are just their names and times.
        if compact && mark == .upcoming && job.isActive { return nil }
        var parts = [stage.detail ?? ""]
        // Work says its round (Sangam's design), when the runner's line doesn't already.
        // Only with more than one round (Sangam's design): "Round 1 of 1" from the runner goes too.
        if stage.key == "work", job.maxRounds <= 1, parts[0].hasPrefix("Round 1 of 1") {
            parts[0] = String(parts[0].dropFirst("Round 1 of 1".count)).trimmingPrefix(" · ").description
        }
        if stage.key == "work", job.maxRounds > 1, !(stage.detail ?? "").hasPrefix("Round ") {
            parts.insert("Round \(job.currentRound) of \(max(job.currentRound, job.maxRounds))", at: 0)
        }
        let diff = stage.key == "work" && mark == .done ? facts?.diff : nil
        if stage.key == "work", mark == .done {
            if let commits = job.commits, commits > 0 { parts.append("\(commits) commit\(commits == 1 ? "" : "s")") }
            if let files = diff?.files { parts.append("\(files) file\(files == 1 ? "" : "s")") }
        }
        let line = parts.filter { !$0.isEmpty }.joined(separator: " · ")
        guard !line.isEmpty || diff?.added != nil || diff?.removed != nil else { return nil }
        var text = Text(line)
        if let diff, diff.added != nil || diff.removed != nil {
            text = text + Text(line.isEmpty ? "" : " ") + Text(diff.added.map { "+\($0)" } ?? "").foregroundStyle(Tokens.done)
                + Text(diff.removed.map { " −\($0)" } ?? "").foregroundStyle(Tokens.danger)
        }
        return text
    }

    /// Under the line: what the current stage is doing and why; where a failure left things.
    private func sub(_ stage: JobStage, mark: TaskFacts.Mark) -> String? {
        if mark == .current || mark == .needs { return facts?.context }
        guard mark == .failed else { return nil }
        if let sent = job.outgoing?.last { return "Stopped here, after: \(sent.line)." }
        if let commits = job.commits, commits > 0 {
            return "Stopped here. Nothing went out: the \(commits == 1 ? "commit stays" : "\(commits) commits stay") on \(job.branch)."
        }
        return "Stopped here. Nothing went out."
    }

    @ViewBuilder private func inner(_ stage: JobStage, mark: TaskFacts.Mark, now: Date) -> some View {
        switch stage.key {
        case "work": work(mark: mark, now: now)
        case "check": checks(mark: mark)
        case "publish": publish(mark: mark)
        default: EmptyView()
        }
    }

    /// Under Work: the counts and groups while it runs (only finished groups while it waits on you),
    /// and once done, the counts on one line that opens the session.
    @ViewBuilder private func work(mark: TaskFacts.Mark, now: Date) -> some View {
        if let activity = facts?.activity {
            let groups = activity.groups ?? []
            if mark == .current || (mark == .needs && !compact) {
                if activity.counts?.line != nil || !groups.isEmpty {
                    StageBox {
                        if let counts = activity.counts, counts.line != nil { CountChips(counts: counts, scrolls: compact) }
                        if !groups.isEmpty && !(compact && !groups.contains(where: \.running)) {
                            ActivityGroups(groups: groups, now: now, compact: compact).padding(.top, 10)
                        }
                    }
                }
            } else if mark == .done || mark == .failed, let line = activity.counts?.line {
                Button { onSession?() } label: {
                    HStack(spacing: 6) {
                        Text(line).font(Tokens.font(Tokens.textSm)).foregroundStyle(Tokens.muted)
                            .multilineTextAlignment(.leading)
                        if onSession != nil { Image(systemName: "chevron.right").font(Tokens.font(9, .semibold)).foregroundStyle(Tokens.muted) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(onSession == nil).padding(.top, 8)
            }
        }
    }

    /// Under Check: the last round's commands, once obid serves them.
    @ViewBuilder private func checks(mark: TaskFacts.Mark) -> some View {
        if let round = facts?.checks?.last, !round.steps.isEmpty, !(compact && mark != .current) {
            StageBox { CheckRows(steps: round.steps, compact: compact) }
        }
    }

    /// Under Publish: the secret scan and what went out.
    @ViewBuilder private func publish(mark: TaskFacts.Mark) -> some View {
        let scan = facts?.scan
        let sent = job.outgoing ?? []
        if !compact, mark != .skipped, scan?.ran != nil || !sent.isEmpty {
            StageBox {
                VStack(alignment: .leading, spacing: 7) {
                    if let scan, let ran = scan.ran { scanRow(scan, ran: ran) }
                    ForEach(Array(sent.enumerated()), id: \.offset) { _, item in FactRow(mark: .done, text: item.line) }
                }
            }
        }
    }

    private func scanRow(_ scan: JobScan, ran: Bool) -> some View {
        let what = [scan.commits.map { "\($0) commit\($0 == 1 ? "" : "s")" }, scan.files.map { "\($0) file\($0 == 1 ? "" : "s")" }]
            .compactMap { $0 }.joined(separator: ", ")
        let note: String? = !ran ? scan.reason ?? "didn't run" : scan.clean == true ? (what.isEmpty ? "clean" : "clean · \(what)")
            : "\(scan.findings?.count ?? 0) possible secret\(scan.findings?.count == 1 ? "" : "s")"
        return FactRow(mark: !ran ? .skipped : scan.clean == true ? .done : .failed, text: "Secret scan", note: note,
                       time: scan.seconds.map(JobPageText.seconds))
    }
}

/// The usage line (`.use-line`): this job's tokens and their API price, then its share of the
/// account's 5-hour and weekly windows, the job's part in ink.
struct JobUsageLine: View {
    let usage: JobUsage?
    let share: WindowShare?
    /// The account's windows, 0...1, and its name.
    let account: Usage.Snapshot?
    var done = false
    var compact = false

    /// Whether there's anything of this job's to show.
    static func shows(_ facts: JobFacts?) -> Bool { facts?.usage?.tokens != nil || facts?.usage?.costUsd != nil || facts?.windowShare != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let tokens = tokenLine { tokens.font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.text).fixedSize(horizontal: false, vertical: true) }
            CenteredFlow(spacing: 18, centred: false) {
                if let used = account?.fiveHour { window("5-hour", used: used, job: share?.fiveHour) }
                if let used = account?.sevenDay { window("Week", used: used, job: share?.sevenDay) }
            }
        }
    }

    private var tokenLine: Text? {
        var parts: [Text] = []
        if let tokens = usage?.tokens { parts.append(Text(JobPageText.tokens(tokens)).foregroundStyle(Tokens.ink).fontWeight(.medium) + Text(" tokens")) }
        if let cost = usage?.costUsd {
            parts.append(Text("\(JobPageText.dollars(cost)) at API prices" + (!compact && usage?.priced == "plan" ? ", covered by your plan" : "")))
        }
        if !compact, let account { parts.append(Text(account.name)) }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ") + $1 }
    }

    private func window(_ name: String, used: Double, job: Double?) -> some View {
        let total = min(100, max(0, used * 100)), mine = job.map { min(total, max(0, $0)) }
        return HStack(spacing: 8) {
            Text(name)
            HStack(spacing: 2) {
                if let mine, mine > 0 { Rectangle().fill(Tokens.ink).frame(width: 72 * mine / 100) }
                Rectangle().fill(Tokens.check).frame(width: 72 * max(0, total - (mine ?? 0)) / 100)
                Spacer(minLength: 0)
            }
            .frame(width: 72, height: 4).background(Tokens.meter).clipShape(Capsule())
            (Text("\(JobPageText.percent(total))") + Text(mine == nil ? "" : " · this job \(done ? "used " : "")")
                + Text(mine.map { "≈ \(JobPageText.percent($0))" } ?? "").foregroundStyle(Tokens.ink))
        }
        .font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name): \(JobPageText.percent(total)) used" + (mine.map { ", \(JobPageText.percent($0)) by this job" } ?? ""))
    }
}

/// "What went out" (`.out`): each thing Oby sent for the job, with its time.
struct WentOut: View {
    let outgoing: [Outgoing]

    var body: some View {
        if !outgoing.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("What went out").font(Tokens.font(Tokens.textSm, .medium)).foregroundStyle(Tokens.label).padding(.bottom, 2)
                ForEach(Array(outgoing.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 8) {
                        TimelineMark(mark: .done, size: 8).frame(width: 12, height: 12)
                        Text(item.line).font(Tokens.font(Tokens.textMd)).foregroundStyle(Tokens.muted).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Text(item.date.formatted(date: .omitted, time: .shortened)).font(Tokens.font(Tokens.textSm)).monospacedDigit().foregroundStyle(Tokens.muted)
                    }
                }
            }
        }
    }
}

/// The failed card's choices (Sangam's #741): another round first, the session, and Stop here.
nonisolated enum FailedChoice: String {
    case round, session, dismiss

    /// The words another round sends its agent: the same as Try again's (#725).
    static let roundWords = "Try again, picking up where you left off. Finish with a short summary as asked."

    static func options(session: Bool) -> [CardOption] {
        [CardOption(label: "Give it another round", answer: round.rawValue, recommended: true)]
            + (session ? [CardOption(label: "Open the session", answer: Self.session.rawValue)] : [])
            + [CardOption(label: "Stop here", answer: dismiss.rawValue)]
    }
}
