package com.deskree.oby

import java.time.Duration
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.Locale

// What the screens work out with no view in the way, ported from apps/shared (JobList.swift,
// ChatThread.swift, ChatRuns.swift, Decisions.swift, Usage.swift, TaskFacts.swift, Harness.swift,
// ReachNotice.swift, RemoteRoute.swift, WindowTrail.swift's HomeLine) and the iPhone's Phone.swift,
// so the words and rules stay the same on both phones.

object Format {
    private fun zone() = ZoneId.systemDefault()
    fun time(i: Instant): String = DateTimeFormatter.ofLocalizedTime(FormatStyle.SHORT).withLocale(Locale.getDefault()).format(i.atZone(zone()))
    fun weekday(i: Instant): String = DateTimeFormatter.ofPattern("EEEE", Locale.getDefault()).format(i.atZone(zone()))
    fun weekdayShort(i: Instant): String = DateTimeFormatter.ofPattern("EEE", Locale.getDefault()).format(i.atZone(zone()))
    fun monthDay(i: Instant): String = DateTimeFormatter.ofPattern("MMM d", Locale.getDefault()).format(i.atZone(zone()))
    fun dateTime(i: Instant): String = DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withLocale(Locale.getDefault()).format(i.atZone(zone()))
    fun sameDay(a: Instant, b: Instant) = a.atZone(zone()).toLocalDate() == b.atZone(zone()).toLocalDate()
    fun seconds(from: Instant, to: Instant) = Duration.between(from, to).toMillis() / 1000.0
}

object Elapsed {
    fun waiting(since: Instant, now: Instant = Instant.now()): String {
        val s = maxOf(0L, Duration.between(since, now).seconds)
        return when {
            s < 60 -> "just now"
            s < 3600 -> "waiting ${s / 60}m"
            s < 86400 -> "waiting ${s / 3600}h"
            else -> "waiting ${s / 86400}d"
        }
    }
}

object JobList {
    fun shows(finished: Instant?, clearedAt: Instant?): Boolean {
        if (finished == null || clearedAt == null) return true
        return finished > clearedAt
    }

    /** A new list from the runner (its latest 50), keeping the jobs whose screens are open. */
    fun keeping(fresh: List<Job>, old: List<Job>, onScreen: Set<String>): Pair<List<Job>, List<String>> {
        val missing = onScreen - fresh.map { it.id }.toSet()
        var list = fresh
        for (job in old) if (job.id in missing) list = placed(job, list)
        return list to missing.sorted()
    }

    /** `job` in the list: in place of the one with its id, else where its age puts it (newest first). */
    fun placed(job: Job, list: List<Job>): List<Job> {
        val out = list.toMutableList()
        val at = out.indexOfFirst { it.id == job.id }
        if (at >= 0) out[at] = job else {
            val before = out.indexOfFirst { it.created < job.created }
            out.add(if (before < 0) out.size else before, job)
        }
        return out
    }
}

enum class GroupBy(val label: String) { Type("Type"), Status("Status") }
enum class WorkStatus { Running, Needs, Done }
enum class WorkMark(val spoken: String) { New("New"), Needs("Needs you"), Working("Working"), Queued("Queued"), Done("Done") }

sealed class WorkType(val id: String, val label: String, val order: Int) {
    data object Review : WorkType("review", "Review PR", 0)
    data object Issues : WorkType("issues", "Issues", 1)
    data class Teammate(val name: String) : WorkType("teammate:$name", name, 2)
    data object Tasks : WorkType("tasks", "Tasks", 3)
    data object Routines : WorkType("routines", "Routines", 4)

    companion object {
        fun of(review: Boolean, issue: Int?, requester: String?, routine: Boolean = false): WorkType {
            requester?.trim()?.takeIf { it.isNotEmpty() }?.let { return Teammate(it) }
            if (routine) return Routines
            if (review) return Review
            return if (issue == null) Tasks else Issues
        }
        val comparator = compareBy<WorkType>({ it.order }, { (it as? Teammate)?.name ?: "" })
    }
}

data class WorkItem(val id: String, val job: Job, val type: WorkType, val status: WorkStatus, val queued: Boolean, val fresh: Boolean) {
    val mark: WorkMark get() = when {
        fresh -> WorkMark.New
        status == WorkStatus.Needs -> WorkMark.Needs
        status == WorkStatus.Done -> WorkMark.Done
        queued -> WorkMark.Queued
        else -> WorkMark.Working
    }
}

data class WorkGroup(val id: String, val type: WorkType?, val label: String, val items: List<WorkItem>, val count: Int,
                     val countLabel: String, val needs: Int, val fresh: Boolean)

enum class WorkTab(val label: String) { Todo("To do"), Running("Running"), Done("Completed") }

object WorkList {
    fun groups(items: List<WorkItem>, by: GroupBy): List<WorkGroup> = when (by) {
        GroupBy.Type -> items.map { it.type }.distinct().sortedWith(WorkType.comparator).map { kind ->
            val list = ranked(items.filter { it.type == kind })
            WorkGroup(kind.id, kind, kind.label, list, list.count { it.status != WorkStatus.Done }, "open",
                      list.count { it.status == WorkStatus.Needs }, list.any { it.fresh })
        }
        GroupBy.Status -> listOf(Triple(WorkStatus.Needs, "needs", "Needs you"), Triple(WorkStatus.Running, "running", "Running"),
                                 Triple(WorkStatus.Done, "done", "Completed")).mapNotNull { (status, id, label) ->
            val list = ranked(items.filter { it.status == status })
            if (list.isEmpty()) null else WorkGroup("status:$id", null, label, list, list.size, "tasks",
                                                    if (status == WorkStatus.Needs) list.size else 0, list.any { it.fresh })
        }
    }

    fun kinds(items: List<WorkItem>): List<WorkGroup> {
        val held = groups(items, GroupBy.Type)
        val always = listOf(WorkType.Review, WorkType.Issues, WorkType.Tasks, WorkType.Routines)
        return (always + held.mapNotNull { it.type }).distinct().sortedWith(WorkType.comparator).map { kind ->
            held.firstOrNull { it.type == kind } ?: WorkGroup(kind.id, kind, kind.label, emptyList(), 0, "open", 0, false)
        }
    }

    fun ranked(items: List<WorkItem>): List<WorkItem> {
        fun rank(i: WorkItem) = if (i.fresh) 0 else if (i.status == WorkStatus.Needs) 1 else if (i.queued) 2 else 3
        return items.withIndex().sortedWith(compareBy({ rank(it.value) }, { it.index })).map { it.value }
    }

    fun shown(group: WorkGroup, more: Boolean): Pair<List<WorkItem>, Int> {
        val keep = if (group.id == "status:done") 5 else 3
        val done = group.items.filter { it.status == WorkStatus.Done }
        val hidden = maxOf(0, done.size - keep)
        if (more) return group.items to hidden
        return group.items.filter { it.status != WorkStatus.Done } + done.take(keep) to hidden
    }

    fun needsYou(items: List<WorkItem>, loose: Int) = items.count { it.status == WorkStatus.Needs } + loose

    fun items(items: List<WorkItem>, tab: WorkTab) =
        if (tab == WorkTab.Todo) emptyList() else items.filter { (it.status == WorkStatus.Done) == (tab == WorkTab.Done) }

    fun counts(items: List<WorkItem>, toDo: Int?, upcoming: Int = 0): Map<WorkTab, Int> {
        val counts = mutableMapOf(WorkTab.Running to items(items, WorkTab.Running).size + upcoming, WorkTab.Done to items(items, WorkTab.Done).size)
        if (toDo != null) counts[WorkTab.Todo] = toDo
        return counts
    }

    fun firstTab(items: List<WorkItem>, toDo: Boolean = false): WorkTab {
        items.firstOrNull { it.fresh }?.let { return if (it.status == WorkStatus.Done) WorkTab.Done else WorkTab.Running }
        if (items.any { it.status != WorkStatus.Done }) return WorkTab.Running
        if (toDo) return WorkTab.Todo
        return if (items.isEmpty()) WorkTab.Running else WorkTab.Done
    }
}

/** Where the phone's stack can go (apps/ios/app/Home.swift's Route). */
sealed interface Route {
    data class Kind(val kind: WorkType) : Route
    data class Task(val id: String) : Route
    data class Conversation(val id: String?) : Route
    data object NewConversation : Route
    data object All : Route
    data object Archived : Route
    data object Inbox : Route
    data object Settings : Route
    data object Connect : Route
}

/** The jobs as Home's work (apps/ios/app/Phone.swift's PhoneWork). */
object PhoneWork {
    fun items(jobs: List<Job>, inbox: List<InboxItem>, since: Instant, seen: Set<String>): List<WorkItem> {
        val asked = inbox.map { it.job }.toSet()
        return jobs.withIndex().sortedWith(compareByDescending<IndexedValue<Job>> { it.value.finished ?: it.value.created }.thenBy { it.index })
            .map { (_, job) ->
                val decides = job.needsYou || job.waitsForAnswer || job.waitsForPermission || job.id in asked
                val status = if (decides) WorkStatus.Needs else if (job.isActive) WorkStatus.Running else WorkStatus.Done
                WorkItem(job.id, job, WorkType.of(job.kind == "review", job.issue, null, job.routine != null), status,
                         job.st == JobStatus.queued, job.created > since && job.id !in seen)
            }
    }

    fun archived(jobs: List<Job>, clearedAt: Instant?, here: Set<String>) =
        jobs.filter { !it.isActive && (it.dismissed != null || it.id in here || !it.listed(clearedAt)) }

    fun loose(inbox: List<InboxItem>, among: List<WorkItem>): List<InboxItem> {
        val listed = among.map { it.id }.toSet()
        return inbox.filter { it.job !in listed }
    }

    fun firstNeeding(items: List<WorkItem>, inbox: List<InboxItem>): Route? {
        inbox.firstOrNull()?.let { first -> return if (items.any { it.id == first.job }) Route.Task(first.job) else Route.Inbox }
        return WorkList.ranked(items).firstOrNull { it.status == WorkStatus.Needs }?.let { Route.Task(it.id) }
    }

    fun running(items: List<WorkItem>) = WorkList.ranked(items.filter { it.status != WorkStatus.Done }).take(3)

    fun step(item: WorkItem, decision: InboxItem?): String {
        val job = item.job
        if (item.status == WorkStatus.Needs) {
            val plan = job.questionValue?.plan != null
            val kind = decision?.let { AskKind.label(it.kind, plan) } ?: when {
                job.waitsForPermission -> "Permission"
                job.waitsForAnswer -> AskKind.label("question", plan)
                job.reviewStopped -> AskKind.label("review")
                job.mergeStopped -> AskKind.label("merge")
                else -> AskKind.label("failed")
            }
            return "Needs you · $kind"
        }
        if (item.queued) return job.waitingValue?.let { "Queued · ${it.text}" } ?: "Queued"
        return job.step.ifEmpty { "Working" }
    }

    fun recent(conversations: List<RunnerConversation>) = conversations.sortedByDescending { it.latest }.take(3)
}

object HomeLine {
    const val IDLE = "All quiet. Give me something to work on"

    fun attention(running: Int, needs: Int): String {
        val r = "$running running task${if (running == 1) "" else "s"}"
        val n = "$needs need${if (needs == 1) "s" else ""} you"
        return when {
            running > 0 && needs > 0 -> "$r · $n"
            running > 0 -> "$r · nothing needs you"
            needs > 0 -> n
            else -> IDLE
        }
    }

    fun placeholder(fullName: String): String {
        val first = fullName.split(" ").firstOrNull().orEmpty()
        return if (first.isEmpty()) "What do you want me to work on?" else "What do you want me to work on, $first?"
    }

    /** The phone doesn't know its owner's name: the linked Mac's own often says it ("Wellington's MacBook Pro"). */
    fun owner(ofMac: String?): String? {
        val name = ofMac ?: return null
        val mark = name.indexOfFirst { it == '\'' || it == '’' }
        if (mark < 0 || !name.substring(mark + 1).startsWith("s ")) return null
        val owner = name.substring(0, mark).trim()
        return if (owner.isEmpty() || ' ' in owner) null else owner
    }
}

object ChatThread {
    const val TOLERANCE = 60L

    fun words(text: String): String? = text.trim().takeIf { it.isNotEmpty() }

    fun lists(turn: Turn, echo: Turn): Boolean {
        if (turn.id == echo.id) return true
        if (turn.conversation != null) return false
        return turn.who == Who.user && turn.date >= echo.date.minusSeconds(TOLERANCE) &&
            (turn.text == echo.text || turn.text.endsWith("The user answered: ${echo.text})"))
    }

    fun pending(echoes: List<Turn>, runner: List<Turn>) = echoes.filter { echo -> runner.none { lists(it, echo) } }

    fun cardLine(job: Job, account: String) = listOf(job.agentName, account, job.line).filter { it.isNotEmpty() }.joinToString(" · ")
}

object ChatRuns {
    const val GAP = 3600L

    data class Row(val turn: Turn, val continues: Boolean, val endsRun: Boolean)

    fun rows(turns: List<Turn>): List<Row> = turns.indices.map { i ->
        val turn = turns[i]
        Row(turn, turns.getOrNull(i - 1)?.let { same(it, turn) } ?: false, turns.getOrNull(i + 1)?.let { !same(turn, it) } ?: true)
    }

    private fun same(first: Turn, next: Turn) = first.who == next.who && Duration.between(first.date, next.date).seconds < GAP

    fun clock(date: Instant, now: Instant = Instant.now()): String {
        val time = Format.time(date)
        if (Format.sameDay(date, now)) return time
        if (Duration.between(date, now).abs().seconds < 6 * 86_400) return Format.weekdayShort(date) + " " + time
        return Format.monthDay(date) + ", " + time
    }
}

object ConversationOrder {
    fun ordered(list: List<RunnerConversation>) =
        list.sortedWith(compareByDescending<RunnerConversation> { if (it.pinned) 1 else 0 }.thenByDescending { it.latest })

    fun sections(list: List<RunnerConversation>): Pair<List<RunnerConversation>, List<RunnerConversation>> {
        val sorted = ordered(list)
        return sorted.filter { it.pinned } to sorted.filter { !it.pinned }
    }

    fun placed(conversation: RunnerConversation, list: List<RunnerConversation>): List<RunnerConversation> {
        val out = list.filter { it.id != conversation.id }.toMutableList()
        if (!conversation.deleted) out += conversation
        return ordered(out)
    }

    fun started(said: String, conversation: RunnerConversation): Boolean {
        if (conversation.deleted || conversation.title.isEmpty()) return false
        val first = said.trim().lineSequence().firstOrNull().orEmpty()
        if (!conversation.title.endsWith("…")) return first.equals(conversation.title, ignoreCase = true)
        val cut = conversation.title.dropLast(1).trim()
        return cut.isNotEmpty() && first.lowercase().startsWith(cut.lowercase())
    }

    fun shows(conversation: String?, current: String?, startingNew: Boolean): Boolean {
        val id = conversation ?: return true
        return !startingNew && id == current
    }

    fun ago(date: Instant, now: Instant = Instant.now()): String {
        val minutes = Duration.between(date, now).toMillis() / 60000.0
        return when {
            minutes < 1 -> "now"
            minutes < 60 -> "${Math.round(minutes)}m"
            minutes < 24 * 60 -> "${(minutes / 60).toInt()}h"
            else -> "${(minutes / 1440).toInt()}d"
        }
    }
}

object AskKind {
    fun label(kind: String, plan: Boolean = false): String = when (kind) {
        "question" -> if (plan) "Plan" else "Question"
        "permission" -> "Permission"
        "review" -> "Out of reviews"
        "limit" -> "Out of usage"
        "start", "github" -> "Start it?"
        "merge" -> "Not merged"
        "audit" -> "Issue audit"
        "failure" -> "Oby failure"
        RunnerConfirm.KIND -> "Confirm it?"
        else -> "Failed"
    }

    fun failed(kind: String) = kind !in listOf("question", "permission", "review", "limit", "start", "github", "audit", RunnerConfirm.KIND)
}

object ThreadTaskLine {
    fun status(mark: WorkMark) = when (mark) {
        WorkMark.Queued -> "Queued"; WorkMark.Working -> "Running"; WorkMark.Needs -> "Needs you"; WorkMark.Done -> "Done"; WorkMark.New -> "New"
    }

    fun meta(job: Job, mark: WorkMark, account: String) =
        (listOf(status(mark), job.agentName, account) + listOf(job.repoName)).filter { it.isNotEmpty() }.joinToString(" · ")

    fun followUp(next: Job, account: String): String {
        val repo = if ('/' in next.repo) " in ${next.repoName}" else ""
        return "This one’s finished, so I started a follow-up. ${next.agentName} has it$repo on ${account.ifEmpty { next.account }}."
    }

    fun followUps(id: String, jobs: List<Job>) = jobs.filter { it.followUpOf == id }.sortedBy { it.created }

    fun startedBy(turn: String?, conversation: String?, showing: String?) = if (conversation == showing) turn else null

    fun cards(under: Turn, thread: List<Turn>, jobs: List<Job>, startedBy: (Job) -> String?): List<Job> {
        val listed = ConversationModel.jobsOf(under, jobs)
        if (under.who != Who.user) return listed
        val answered = thread.flatMap { it.jobs.orEmpty() }.toSet()
        return listed + jobs.filter { startedBy(it) == under.id && it.id !in answered }.sortedBy { it.created }
    }

    fun shown(thread: List<Turn>, jobs: List<Job>, startedBy: (Job) -> String?, ended: (Turn) -> Boolean): Set<String> {
        val words = thread.filter { it.who == Who.user }.map { it.id }.toSet()
        return thread.filter { !ended(it) }.flatMap { it.jobs.orEmpty() }.toSet() + jobs.filter { startedBy(it)?.let { t -> t in words } ?: false }.map { it.id }
    }

    fun attached(job: Job, jobs: List<Job>, shown: Set<String>, seen: Set<String> = emptySet()): List<Job> {
        val now = seen + job.id
        return followUps(job.id, jobs).filter { it.id !in shown && it.id !in now }.flatMap { listOf(it) + attached(it, jobs, shown, now) }
    }

    fun mark(job: Job): WorkMark = when {
        job.needsYou || job.waitsForAnswer || job.waitsForPermission -> WorkMark.Needs
        job.isActive -> if (job.st == JobStatus.queued) WorkMark.Queued else WorkMark.Working
        else -> WorkMark.Done
    }
}

enum class UsageDot { None, High, Over;
    companion object {
        fun of(weeks: List<Double?>): UsageDot {
            val most = weeks.filterNotNull().maxOrNull() ?: 0.0
            return if (most > 0.9) Over else if (most > 0.8) High else None
        }
    }
}

/** Oby's words coming in a word at a time (Sangam's stream.ts): one every 35 ms, each fading in over 240 ms. */
object WordReveal {
    const val WORD = 0.035
    const val FADE = 0.24

    fun words(text: String): List<String> = Regex("\\S+\\s*").findAll(text).map { it.value }.toList()

    fun starts(count: Int, came: List<Double> = emptyList()): List<Double> {
        var last = 0.0
        return (0 until count).map { i -> last = maxOf(came.getOrElse(i) { 0.0 }, last + WORD); last }
    }

    fun duration(text: String, came: List<Double> = emptyList()) = (starts(words(text).size, came).lastOrNull() ?: 0.0) + FADE

    /** The words so far after `elapsed` seconds, and how far in the last of them still fading are. */
    fun shown(text: String, came: List<Double> = emptyList(), elapsed: Double): Pair<String, List<Double>> {
        val words = words(text)
        val starts = starts(words.size, came)
        val count = starts.indexOfFirst { it > elapsed + 1e-9 }.let { if (it < 0) words.size else it }
        val fading = starts.take(count).map { minOf(1.0, (elapsed - it) / FADE) }.filter { it < 1 }
        return words.take(count).joinToString("") to fading
    }
}

/** What Oby's words set apart as you read them (Sangam's textTokens.ts). */
object SaidTokens {
    enum class Kind { Url, Code, Ref, Path }

    private val patterns = listOf(
        Kind.Url to Regex("\\bhttps?://[^\\s<>\"'`]*[^\\s<>\"'`.,;:!?)\\]}]"),
        Kind.Code to Regex("`[^`\\n]+`"),
        Kind.Ref to Regex("(?<![\\w#])(?:[\\w.-]+/)?(?:[\\w.-]+)?#\\d+(?!\\w)"),
        Kind.Path to Regex("(?<![\\w.:/@-])(?:~/|\\.{1,2}/|/)?(?:[\\w@.-]+/)+[\\w@.-]+"),
    )

    data class Match(val range: IntRange, val kind: Kind)

    fun matches(text: String): List<Match> {
        val found = mutableListOf<Triple<IntRange, Int, Kind>>()
        patterns.forEachIndexed { order, (kind, regex) ->
            for (m in regex.findAll(text)) {
                var range = m.range
                if (kind == Kind.Path && text.substring(range).endsWith(".")) range = range.first until range.last
                found += Triple(range, order, kind)
            }
        }
        found.sortWith(compareBy({ it.first.first }, { it.second }))
        val out = mutableListOf<Match>()
        var end = 0
        for ((range, _, kind) in found) {
            if (range.first >= end && !range.isEmpty()) {
                out += Match(range, kind)
                end = range.last + 1
            }
        }
        return out
    }
}

/** One answer on a decision card. */
data class CardOption(val label: String, val answer: String, val detail: String? = null, val recommended: Boolean = false,
                      val destructive: Boolean = false) {
    val safeOnReturn: Boolean get() {
        val action = answer.lowercase().trim()
        return !destructive && listOf("deny", "dismiss", "stop").none { action == it || action.startsWith("$it ") }
    }

    companion object {
        const val MOST = 4

        fun of(options: List<String>, recommended: Int? = null): List<CardOption> {
            val list = options.mapIndexed { i, o -> CardOption(o, o, recommended = i == recommended) }.toMutableList()
            val at = list.indexOfFirst { it.recommended }
            if (at > 0) list.add(0, list.removeAt(at))
            return list.take(MOST)
        }

        fun ofRecommending(options: List<String>, label: String?) = of(options, label?.let { options.indexOf(it).takeIf { i -> i >= 0 } })

        fun permission(permission: RunnerPermission): List<CardOption> {
            val list = mutableListOf(CardOption("Allow once", "allow", recommended = true))
            InboxWords.plain(permission.rule)?.let { rule ->
                val always = permission.always ?: "Always allow $rule"
                list += CardOption("Always allow", "always", detail = if (rule in always) always else "$always · $rule")
            }
            list += CardOption("Deny", "deny", destructive = true)
            return list
        }

        fun inbox(options: List<String>, kind: String, question: Question?, permission: RunnerPermission?, words: InboxWords?,
                  details: List<String>?, does: String?): List<CardOption> {
            if (kind == RunnerConfirm.KIND) {
                val lines = details?.takeIf { it.size == options.size }
                return options.mapIndexed { i, o ->
                    CardOption(o, o, detail = if (o == RunnerConfirm.CONFIRM) InboxWords.plain(does) else InboxWords.plain(lines?.get(i)))
                }.take(MOST)
            }
            val ours = words?.recommended?.takeIf { it in options.indices }
            val list = (ours?.let { of(options, it) } ?: ofRecommending(options, if (kind == "question") question?.recommendedOption else null)).toMutableList()
            val doesMap = details?.takeIf { it.size == options.size }?.let { options.zip(it).toMap() }.orEmpty()
            for (i in list.indices) {
                var o = list[i]
                InboxWords.plain(doesMap[o.answer])?.let { o = o.copy(detail = it) }
                if (kind == "permission" && o.label == "Allow") o = o.copy(label = "Allow once")
                if (kind == "permission" && o.label == "Always allow") InboxWords.plain(permission?.rule)?.let { rule ->
                    val friendly = permission?.always ?: "Always allow $rule"
                    o = o.copy(detail = if (rule in friendly) friendly else "$friendly · $rule")
                }
                if (kind == "permission" && o.label == "Deny") o = o.copy(destructive = true)
                if (o.recommended) InboxWords.plain(words?.why)?.let { why -> o = o.copy(detail = listOfNotNull(o.detail, why).joinToString("\n")) }
                list[i] = o
            }
            if (kind == "permission" && InboxWords.plain(permission?.rule) == null) list.removeAll { it.label == "Always allow" }
            return list
        }
    }
}

enum class RunnerMode(val label: String, val help: String) {
    ask("Ask", "Asks before it edits a file or runs a command"),
    acceptEdits("Accept edits", "Edits files without asking; asks before commands"),
    plan("Plan", "Plans first, and works once you approve the plan"),
    bypass("Bypass", "Asks nothing"),
    sandbox("Sandbox", "Asks only about the network, secrets and reads outside the worktree");

    companion object { fun of(raw: String?) = entries.firstOrNull { it.name == raw } }
}

/** A plan in markdown, split into what the card draws. */
sealed interface PlanBlock {
    data class Heading(val text: String) : PlanBlock
    data class Item(val marker: String, val text: String) : PlanBlock
    data class Code(val text: String) : PlanBlock
    data class Text(val text: String) : PlanBlock

    companion object {
        fun blocks(markdown: String): List<PlanBlock> {
            val blocks = mutableListOf<PlanBlock>()
            var code: MutableList<String>? = null
            val paragraph = mutableListOf<String>()
            fun flush() { if (paragraph.isNotEmpty()) blocks += Text(paragraph.joinToString(" ")); paragraph.clear() }
            for (raw in markdown.split("\n")) {
                val line = raw.trim()
                if (line.startsWith("```")) {
                    val open = code
                    if (open != null) { blocks += Code(open.joinToString("\n")); code = null } else { flush(); code = mutableListOf() }
                    continue
                }
                code?.let { it += raw; continue }
                if (line.isEmpty()) { flush(); continue }
                val numbered = Regex("^(\\d{1,3})[.)] (.*)$").find(line)
                when {
                    line.startsWith("#") -> { flush(); blocks += Heading(line.trimStart('#').trim()) }
                    line.first() in "-*+" && line.getOrNull(1) == ' ' -> { flush(); blocks += Item("•", line.drop(2).trim()) }
                    numbered != null -> { flush(); blocks += Item("${numbered.groupValues[1]}.", numbered.groupValues[2]) }
                    else -> paragraph += line
                }
            }
            code?.let { blocks += Code(it.joinToString("\n")) }
            flush()
            return blocks
        }
    }
}

/** A Markdown artifact in blocks, for the viewer. */
sealed interface MdBlock {
    data class Heading(val level: Int, val text: String) : MdBlock
    data class Code(val text: String) : MdBlock
    data class Text(val text: String) : MdBlock

    companion object {
        fun blocks(markdown: String): List<MdBlock> {
            val blocks = mutableListOf<MdBlock>()
            val lines = mutableListOf<String>()
            var code: MutableList<String>? = null
            fun flush() { lines.joinToString("\n").trim().takeIf { it.isNotEmpty() }?.let { blocks += Text(it) }; lines.clear() }
            for (line in markdown.split("\n")) {
                val hashes = Regex("^(#{1,6})\\s+(.+)$").find(line)
                when {
                    line.startsWith("```") -> { val open = code; if (open != null) { blocks += Code(open.joinToString("\n")); code = null } else { flush(); code = mutableListOf() } }
                    code != null -> code!!.add(line)
                    hashes != null -> { flush(); blocks += Heading(hashes.groupValues[1].length, hashes.groupValues[2]) }
                    line.isBlank() -> flush()
                    else -> lines += line
                }
            }
            code?.let { blocks += Code(it.joinToString("\n")) }
            flush()
            return blocks
        }
    }
}

/** A tool call of the conversation's agent as a line under Oby's words. */
object ToolLine {
    fun parts(step: TurnStep): Pair<String, String?> {
        val what = step.detail?.trim()?.takeIf { it.isNotEmpty() }
        return when (step.tool) {
            "read" -> "Reading" to what
            "search" -> "Searching for" to what
            "web_search" -> (what?.let { "Searching the web for “$it”" } ?: "Searching the web") to null
            "web_fetch" -> "Reading" to what?.let { runCatching { java.net.URI(it).host }.getOrNull() ?: it }
            "bash" -> "Running" to what
            "write" -> "Writing" to what
            "agent" -> "Asking a helper agent" to null
            "oby_dispatch" -> "Starting a job" to null
            "oby_inbox" -> "Checking the inbox" to null
            else -> (step.text.ifEmpty { what ?: "Working" }) to null
        }
    }

    fun text(step: TurnStep): String = parts(step).let { (verb, detail) -> detail?.let { "$verb $it" } ?: verb }
    fun folded(steps: List<TurnStep>, words: Boolean = false) = words || steps.none { it.stepState == StepState.running }
    fun shown(steps: List<TurnStep>) = steps.takeLast(4)

    fun summary(steps: List<TurnStep>): String {
        fun phrase(n: Int, verb: String, one: String, many: String) = if (n == 0) null else if (n == 1) "$verb $one" else "$verb $n $many"
        fun count(vararg tools: String) = steps.count { it.action == "tool" && (it.tool ?: "") in tools }
        val named = listOf("read", "search", "web_search", "web_fetch", "bash", "write", "agent", "oby_dispatch")
        val others = steps.count { it.action != "tool" || (it.tool ?: "") !in named }
        val parts = listOfNotNull(
            phrase(count("read"), "read", "a file", "files"),
            phrase(count("search"), "searched", "the code", "times"),
            if (count("web_search", "web_fetch") > 0) "searched the web" else null,
            phrase(count("bash"), "ran", "a command", "commands"),
            phrase(count("write"), "wrote", "a file", "files"),
            if (count("agent") > 0) "asked a helper agent" else null,
            phrase(count("oby_dispatch"), "started", "a job", "jobs"),
            phrase(others, "took", "a step", "steps"),
        )
        var line = parts.joinToString(", ").replaceFirstChar { it.uppercase() }
        val failed = steps.count { it.stepState == StepState.failed }
        if (failed > 0) line += " · $failed failed"
        return line
    }
}

/** What a task's card and page say (Sangam's TaskCard.tsx). */
object TaskFacts {
    fun duration(seconds: Double): String {
        val minutes = (maxOf(0.0, seconds) / 60).toInt()
        if (minutes < 1) return "now"
        return if (minutes < 60) "${minutes}m" else "${minutes / 60}h ${minutes % 60}m"
    }

    fun ago(job: Job, now: Instant = Instant.now()): String {
        val finished = job.finished
        if (!job.isActive && finished != null) {
            val text = duration(Format.seconds(finished, now))
            return if (text == "now") text else "$text ago"
        }
        return duration(Format.seconds(job.started ?: job.created, now))
    }

    fun pullRequest(published: String?): String? {
        val uri = published?.let { runCatching { java.net.URI(it) }.getOrNull() } ?: return null
        if (uri.host != "github.com") return null
        val parts = uri.path.split("/").filter { it.isNotEmpty() }
        return if (parts.size >= 4 && parts[2] == "pull") "${parts[1]}#${parts[3]}" else null
    }

    fun resultLine(job: Job): String? {
        if (job.isActive) return null
        val parts = mutableListOf<String>()
        job.commits?.takeIf { it > 0 }?.let { parts += "$it commit${if (it == 1) "" else "s"} on ${job.branch}" }
        pullRequest(job.published)?.let { parts += it }
        job.finished?.let { f -> duration(Format.seconds(job.started ?: job.created, f)).takeIf { it != "now" }?.let { parts += "Took $it" } }
        return parts.takeIf { it.isNotEmpty() }?.joinToString(" · ")
    }

    enum class Mark { Done, Current, Needs, Upcoming, Skipped, Failed }

    fun mark(stage: String, needs: Boolean, working: Boolean) = when (stage) {
        "done" -> Mark.Done
        "failed" -> Mark.Failed
        "skipped" -> Mark.Skipped
        "current" -> if (needs) Mark.Needs else if (working) Mark.Current else Mark.Upcoming
        else -> Mark.Upcoming
    }

    fun hasResult(job: Job) = job.summary.isNotEmpty() || resultLine(job) != null || job.commits != null || job.published != null ||
        job.sentLines != null || job.pullRequestError != null || job.canPublish || job.needsYou || job.dismissed != null || job.report == true

    fun facts(job: Job, mode: String?): List<Triple<String, String, Boolean>> {
        val facts = mutableListOf(
            Triple("Repository", job.repo, false), Triple("Branch", job.branch, true),
            Triple("Base", job.base ?: "Repository default", job.base != null),
            Triple("Model", job.model?.let(ModelChoice::name) ?: "Account default", false),
        )
        RunnerMode.of(mode)?.let { facts += Triple("Mode", it.label, false) }
        job.check?.let { facts += Triple("Done when", "$it passes", true) }
        return facts
    }

    fun meta(job: Job, account: String) = listOf(job.agentName, account, job.repoName).filter { it.isNotEmpty() }.joinToString(" · ")
}

/** A task's ⋮ (Sangam's TaskMenu.tsx). */
object TaskMenu {
    enum class Item { OpenConversation, Stop, Archive, Dismiss, Move, Mode }

    fun items(job: Job, conversation: Boolean): List<Item> {
        val items = if (conversation) mutableListOf(Item.OpenConversation) else mutableListOf()
        items += if (job.isActive) Item.Stop else if (job.needsYou || job.canPublish) Item.Dismiss else Item.Archive
        if (job.reviewOf == null) items += Item.Move
        if (job.isActive && job.mode != null) items += Item.Mode
        return items
    }
}

/** The failed card's choices (Sangam's #741). */
object FailedChoice {
    const val ROUND = "round"; const val SESSION = "session"; const val DISMISS = "dismiss"
    fun options(session: Boolean) = listOf(CardOption("Give it another round", ROUND, recommended = true)) +
        (if (session) listOf(CardOption("Open the session", SESSION)) else emptyList()) + listOf(CardOption("Stop here", DISMISS))
}

/** What "Move to…" offers (docs/runner-api.md, `POST /v1/jobs/{id}/move`). */
object MoveChoice {
    val tools = listOf("claude" to "Claude Code", "codex" to "Codex", "cursor" to "Cursor")
    val claudeModels = listOf("claude-fable-5-1", "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5")
    const val CODEX_STRONGEST = "gpt-6-astra"
    const val TOOL_DEFAULT = "default"
    const val ROOM = 0.8

    fun usage(signedIn: Boolean, fiveHour: Double?, sevenDay: Double?): String {
        if (!signedIn) return "Signed out"
        val parts = listOfNotNull(fiveHour?.let { "5h ${Math.round(it * 100)}%" }, sevenDay?.let { "week ${Math.round(it * 100)}%" })
        return if (parts.isEmpty()) "No usage yet" else parts.joinToString(" · ")
    }

    fun busy(fiveHour: Double?, sevenDay: Double?) = maxOf(fiveHour ?: 0.0, sevenDay ?: 0.0) >= ROOM

    fun effect(active: Boolean, running: Boolean) = when {
        running -> "Its agent stops, and the round starts over there with the work so far."
        active -> "It starts there."
        else -> "Its next round runs there: tell it something, or Try again."
    }
}

/** Why the Mac can't be reached, in the same words on every screen (apps/shared/ReachNotice.swift). */
sealed interface ReachNotice {
    data class Unreachable(val lastSeen: Instant?) : ReachNotice
    data class NoInternet(val lastSeen: Instant?) : ReachNotice
    data object Removed : ReachNotice
    data object Expired : ReachNotice

    val title: String get() = when (this) {
        is Unreachable -> "Can't reach your Mac"
        is NoInternet -> "No internet on this phone"
        Removed -> "This phone was removed from your Mac"
        Expired -> "Pairing with your Mac ended"
    }

    val detail: String get() = when (this) {
        is Unreachable -> (lastSeen?.let { "Last seen ${whenSaid(it)}. " } ?: "") + "Check it's on and online."
        is NoInternet -> lastSeen?.let { "Showing what Oby knew at ${whenSaid(it)}." } ?: "Showing what Oby knew."
        Removed -> "Scan the code in Oby on your Mac to connect again."
        Expired -> "It lasts 30 days. Scan the code in Oby on your Mac to connect again."
    }

    companion object {
        const val WAITING = "Sends when your Mac is back"

        fun of(connection: Connection, online: Boolean, status: Int?, paired: Boolean, lastSeen: Instant?, expires: Instant?, now: Instant = Instant.now()): ReachNotice? {
            if (connection !is Connection.Offline) return null
            if (!online) return NoInternet(lastSeen)
            if (paired && status == 401) return if (expires?.let { it <= now } == true) Expired else Removed
            return Unreachable(lastSeen)
        }

        private fun whenSaid(date: Instant) = if (Format.sameDay(date, Instant.now())) Format.time(date) else Format.dateTime(date)
    }
}

sealed interface Connection {
    data object Connecting : Connection
    data object Live : Connection
    data class Offline(val why: String) : Connection
}

/** The Mac this phone is linked to (#285, apps/shared/RemoteRoute.swift). */
@kotlinx.serialization.Serializable
data class MacLink(val name: String, val hostname: String) {
    val tunnelURL get() = "https://$hostname"

    companion object {
        private val tunnel = Regex("oby-[a-z0-9]{16,}(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?){2,}")
        private val tailnet = Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.[a-z0-9-]{1,63}\\.ts\\.net(?::[0-9]{1,5})?")
        fun isHostname(text: String) = text.length <= 253 && (tunnel.matches(text) || tailnet.matches(text))
    }
}

sealed interface RemoteRoute {
    val url: String
    data class Home(override val url: String) : RemoteRoute
    data class Away(override val url: String) : RemoteRoute

    val label get() = if (this is Home) "At home, over the local network" else "Away, through the tunnel"

    companion object {
        fun choose(lan: String?, link: MacLink?, paired: Boolean): RemoteRoute? {
            if (!paired || link == null) return null
            return lan?.let(::Home) ?: Away(link.tunnelURL)
        }

        fun lanURL(host: String, port: Int) = "http://${if (':' in host) "[$host]" else host}:$port"
    }
}

/** What the Mac's pairing QR code carries (apps/mac/app/PairingView.swift). */
@kotlinx.serialization.Serializable
data class GatewayEnvelope(val url: String, val link: MacLink, val secret: String) {
    companion object {
        fun decode(text: String): GatewayEnvelope {
            val envelope = runCatching { wire.decodeFromString(serializer(), text.trim()) }.getOrNull()
                ?: throw RunnerError("That isn't Oby's pairing QR code. Scan the one the Mac's Settings › Runner shows.")
            if (!MacLink.isHostname(envelope.link.hostname) || !envelope.reachesItsMac) {
                throw RunnerError("That invitation doesn't point at the Mac it names, so Oby won't pair with it.")
            }
            return envelope
        }

        /** Plain HTTP only to a home-network address: IPv4's private ranges, or IPv6's unique local (fc00::/7) and link-local (fe80::/10). */
        fun isLocal(host: String): Boolean {
            val h = host.lowercase().trim('[', ']').substringBefore('%')
            if (h.endsWith(".local")) return true
            if (':' in h) {
                if (!h.all { it.isDigit() || it in 'a'..'f' || it == ':' || it == '.' }) return false
                val first = h.substringBefore(':').toIntOrNull(16) ?: return false
                return first and 0xfe00 == 0xfc00 || first and 0xffc0 == 0xfe80
            }
            val parts = h.split(".").mapNotNull { it.toIntOrNull()?.takeIf { n -> n in 0..255 } }
            if (parts.size != 4 || h.split(".").size != 4) return false
            return parts[0] == 10 || (parts[0] == 172 && parts[1] in 16..31) || (parts[0] == 192 && parts[1] == 168) ||
                (parts[0] == 169 && parts[1] == 254)
        }
    }

    /** The URL is the link's own hostname over HTTPS, or plain HTTP to a home-network address. */
    private val reachesItsMac: Boolean get() {
        val uri = runCatching { java.net.URI(url) }.getOrNull() ?: return false
        val host = uri.host?.lowercase() ?: return false
        if (uri.scheme == "https") return (if (uri.port >= 0) "$host:${uri.port}" else host) == link.hostname.lowercase()
        if (uri.scheme != "http") return false
        return isLocal(host)
    }
}

object PairingCode {
    fun normalized(text: String): String? {
        val digits = text.filter { it in '0'..'9' }
        if (digits.length != 6 || !text.all { it in '0'..'9' || it == ' ' || it == '-' }) return null
        return digits
    }
}

class RunnerError(message: String, val status: Int? = null) : Exception(message)
