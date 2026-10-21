package com.deskree.oby

import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.decodeFromJsonElement
import java.time.Instant
import java.time.OffsetDateTime

// The runner's wire (docs/runner-api.md), as apps/shared/Runner.swift reads it on the iPhone. A
// newer runner's keys are ignored, a missing one takes its default, and the job page's facts
// (`Lenient` on the iPhone) are read one by one, so one that can't be read never fails the job.

/** ISO 8601, as the runner writes dates: `2026-10-09T21:43:30Z`, with or without fractions or an offset. */
object InstantSerializer : KSerializer<Instant> {
    override val descriptor = PrimitiveSerialDescriptor("Instant", PrimitiveKind.STRING)
    override fun serialize(encoder: Encoder, value: Instant) = encoder.encodeString(value.toString())
    override fun deserialize(decoder: Decoder): Instant = parseInstant(decoder.decodeString())
        ?: throw IllegalArgumentException("not a date")
}

fun parseInstant(text: String): Instant? =
    runCatching { Instant.parse(text) }.getOrNull() ?: runCatching { OffsetDateTime.parse(text).toInstant() }.getOrNull()

typealias Date = @Serializable(with = InstantSerializer::class) Instant

val wire = Json {
    ignoreUnknownKeys = true
    explicitNulls = false
    coerceInputValues = true
    encodeDefaults = false
}

/** A value the runner sends that this app may not be able to read: nil when it can't. */
inline fun <reified T> JsonElement?.lenient(): T? =
    if (this == null || this is JsonNull) null else runCatching { wire.decodeFromJsonElement<T>(this) }.getOrNull()

enum class JobStatus { queued, running, done, failed, stopped, interrupted;
    companion object { fun of(raw: String) = entries.firstOrNull { it.name == raw } ?: queued }
}

@Serializable data class JobStage(
    val id: String, val title: String, val state: String, val detail: String? = null, val reason: String? = null,
    val started: JsonElement? = null, val finished: JsonElement? = null, val waited: JsonElement? = null, val estimate: JsonElement? = null,
) {
    /** done, current, upcoming, failed or skipped; another reads as upcoming. */
    val stateName: String get() = if (state in listOf("done", "current", "upcoming", "failed", "skipped")) state else "upcoming"
}

@Serializable data class JobPipeline(val stages: List<JobStage> = emptyList(), val number: Int = 0, val total: Int = 0) {
    val label get() = "Stage $number of $total"
}

@Serializable data class PullRequestStatus(val state: String = "OPEN", val reviewDecision: String? = null, val base: String = "")

@Serializable data class Review(val verdict: String, val job: String = "", val round: Int = 1) {
    val label get() = if (verdict == "approved") "Approved" else "Changes requested"
}

@Serializable data class Outgoing(val action: String, val repo: String = "", val id: String = "", val branch: String? = null, val date: Date) {
    val line: String get() = when (action) {
        "push" -> "Pushed ${id.take(7)} to ${branch ?: "its branch"} in $repo"
        "pullRequest" -> "Opened pull request $id"
        "pullRequestEdit" -> "Updated the description of $id"
        "comment" -> "Commented $id"
        "checkRun" -> "Posted the check $id"
        "merge" -> "Squash-merged $id into dev and deleted ${branch ?: "its branch"}"
        else -> "$action $id"
    }
}

@Serializable data class Question(
    val text: String, val options: List<String> = emptyList(), val details: List<String>? = null,
    val recommended: Int? = null, val plan: String? = null,
) {
    val recommendedOption: String? get() = recommended?.let { options.getOrNull(it) }

    /** Its options for a card, each with what it does under it when the asker said (#215). */
    val cardOptions: List<CardOption> get() {
        val list = CardOption.of(options, recommended)
        if (details == null || details.size != options.size) return list
        return list.map { o -> options.indexOf(o.answer).takeIf { it >= 0 }?.let { o.copy(detail = details[it]) } ?: o }
    }
}

@Serializable data class RunnerPermission(
    val id: String, val tool: String? = null, val title: String, val detail: String? = null, val rule: String? = null, val always: String? = null,
)

@Serializable data class Waiting(val kind: String = "", val text: String = "", val job: String? = null, val reserved: List<String>? = null)

@Serializable data class Move(val from: String = "", val to: String = "", val why: String? = null)

@Serializable data class ArtifactRef(val id: String, val version: Int)

@Serializable data class RoutineMark(val id: String, val name: String) {
    val line get() = "From routine: $name"
}

@Serializable data class Stalled(val why: String? = null, val note: String? = null)

@Serializable data class Job(
    val id: String,
    val request: String = "",
    val agent: String = "claude",
    val account: String = "",
    val repo: String = "",
    val branch: String = "",
    val base: String? = null,
    val pr: Int? = null,
    val kind: String = "",
    val task: String = "",
    val title: String? = null,
    val report: Boolean? = null,
    val status: String = "queued",
    val step: String = "",
    val summary: String = "",
    val created: Date,
    val started: Date? = null,
    val finished: Date? = null,
    val commits: Int? = null,
    val published: String? = null,
    val pushed: Int? = null,
    val publishError: String? = null,
    val issue: Int? = null,
    val rounds: Int? = null,
    val round: Int? = null,
    val check: String? = null,
    val model: String? = null,
    val notes: List<String>? = null,
    val pipeline: JsonElement? = null,
    val pullRequest: JsonElement? = null,
    val pullRequestError: String? = null,
    val dismissed: Date? = null,
    val reviewing: String? = null,
    val review: JsonElement? = null,
    val reviewOf: String? = null,
    val outgoing: JsonElement? = null,
    val question: JsonElement? = null,
    val mergeNeedsYou: Boolean? = null,
    val reviewNeedsYou: Boolean? = null,
    val cloudNeedsYou: Boolean? = null,
    val mode: String? = null,
    val permission: JsonElement? = null,
    val moves: JsonElement? = null,
    val waiting: JsonElement? = null,
    val conversation: String? = null,
    val turn: String? = null,
    val artifacts: JsonElement? = null,
    val followUpOf: String? = null,
    val routine: JsonElement? = null,
    val tetrix: JsonElement? = null,
    val reason: String? = null,
    val nextStep: String? = null,
    val resumesAt: JsonElement? = null,
    val stalled: JsonElement? = null,
    // The job page's facts (#739), each read on its own.
    val activity: JsonElement? = null,
    val usage: JsonElement? = null,
    val windowShare: JsonElement? = null,
    val estimate: JsonElement? = null,
    val checks: JsonElement? = null,
    val scan: JsonElement? = null,
    val diff: JsonElement? = null,
    val context: JsonElement? = null,
) {
    val st get() = JobStatus.of(status)
    val pipelineValue: JobPipeline? get() = pipeline.lenient()
    val stages: List<JobStage> get() = pipelineValue?.stages.orEmpty()
    val pr_: PullRequestStatus? get() = pullRequest.lenient()
    val reviewValue: Review? get() = review.lenient()
    val sent: List<Outgoing> get() = outgoing.lenient<List<Outgoing>>().orEmpty()
    val questionValue: Question? get() = question.lenient()
    val permissionValue: RunnerPermission? get() = permission.lenient()
    val waitingValue: Waiting? get() = waiting.lenient()
    val artifactRefs: List<ArtifactRef> get() = artifacts.lenient<List<ArtifactRef>>().orEmpty()
    val routineValue: RoutineMark? get() = routine.lenient()
    val tetrixValue: TetrixJobReport? get() = tetrix.lenient()
    val resumes: Instant? get() = resumesAt.lenient<String>()?.let(::parseInstant)
    val handoffNote: String? get() = stalled.lenient<Stalled>()?.note?.takeIf { it.isNotEmpty() }
    val facts: JobFacts get() = JobFacts.of(this)

    val pullRequestState get() = pr_?.state
    val reviewDecision get() = pr_?.reviewDecision

    val isActive get() = st == JobStatus.queued || st == JobStatus.running
    val maxRounds get() = rounds ?: 1
    val currentRound get() = round ?: 1
    val isWaiting get() = st == JobStatus.queued && waitingValue != null
    val isWorking get() = isActive && !isWaiting
    val waitsForAnswer get() = questionValue != null && dismissed == null && st != JobStatus.stopped
    val waitsForPermission get() = permissionValue != null && isActive
    val waitsToStart get() = st == JobStatus.queued && waitingValue?.kind in listOf("schedule", "limit")
    val mergeStopped get() = dismissed == null && mergeNeedsYou == true
    val cloudStopped get() = dismissed == null && cloudNeedsYou == true
    val reviewStopped get() = reviewNeedsYou == true

    val repoName get() = repo.substringAfterLast('/')
    val agentName get() = mapOf("codex" to "Codex", "cursor" to "Cursor")[agent] ?: "Claude Code"
    val movedLine: String? get() = moves.lenient<List<Move>>()?.lastOrNull()?.let { "Moved from ${it.from} to ${it.to}" }

    val heading: String get() {
        title?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }
        (pr ?: issue)?.let { return "${kind.replaceFirstChar { c -> c.uppercase() }} $repoName #$it" }
        return (task.ifEmpty { request }).lineSequence().firstOrNull() ?: request
    }

    private val firstLine: String? get() = summary.lineSequence().firstOrNull()?.takeIf { summary.isNotEmpty() }

    /** The one line a finished job is known by; a waiting one says what for. */
    val line: String get() {
        val waiting = waitingValue
        if (waiting != null && st == JobStatus.queued) return waitingLine(waiting.text)
        return when (st) {
            JobStatus.queued, JobStatus.running -> step
            JobStatus.done -> firstLine ?: "Done"
            JobStatus.interrupted -> reason ?: firstLine ?: "Needs you"
            JobStatus.failed, JobStatus.stopped -> firstLine ?: status.replaceFirstChar { it.uppercase() }
        }
    }

    val unpublished get() = maxOf(0, (commits ?: 0) - (if (published == null) 0 else pushed ?: commits ?: 0))
    val canPublish get() = st == JobStatus.done && kind != "research" && kind != "review" && base != null && unpublished > 0 &&
        dismissed == null && reviewOf == null && (pullRequestState ?: "OPEN") == "OPEN"
    val stranded get() = st == JobStatus.done && published != null && unpublished > 0 && reviewOf == null &&
        (pr_?.let { it.state != "OPEN" } ?: false)
    val needsYou get() = dismissed == null && (canPublish || stranded || st == JobStatus.failed || st == JobStatus.interrupted ||
        reviewStopped || mergeStopped || cloudStopped)
    val sentLines: String? get() = sent.takeIf { it.isNotEmpty() }?.joinToString("\n", prefix = "Sent by Oby:\n") { "- ${it.line}" }
    val nextStepOffered: String? get() = if (st == JobStatus.interrupted && dismissed == null) nextStep else null
    val resumesLine: String? get() {
        if (nextStepOffered == null) return null
        val at = resumes ?: return null
        return "At ${Format.time(at)}, or now with ${nextStep ?: "Try again"}."
    }
    val needsYouKind: String get() =
        if (Regex("(?i)\\b(usage|rate)[ -]?limit|hit your limit|limit (reached|exceeded)\\b").containsMatchIn(reason ?: "")) "Out of usage" else "Needs you"
    val resumable get() = session != null || (started != null && moves.lenient<List<Move>>().orEmpty().isNotEmpty())
    /** obid's gateway leaves `session` out on purpose: the phone never sees one. */
    private val session: String? get() = null

    val badge: JobBadge get() {
        if (dismissed != null) return JobBadge("Dismissed", Tone.Gray)
        if (waitsForPermission) return JobBadge("Awaiting approval", Tone.Orange)
        if (waitsForAnswer) return JobBadge("Needs input", Tone.Orange)
        if (step == "Waiting for your OK" && isActive) return JobBadge("Awaiting approval", Tone.Orange)
        return when (st) {
            JobStatus.queued -> if (waitingValue != null) JobBadge("Waiting", Tone.Gray) else JobBadge("Starting", Tone.Blue)
            JobStatus.running -> JobBadge("Working", Tone.Blue)
            JobStatus.done -> when {
                canPublish -> JobBadge("Ready to publish", Tone.Orange)
                reviewStopped || mergeStopped || cloudStopped -> JobBadge("Needs input", Tone.Orange)
                pullRequestState == "MERGED" -> JobBadge("Merged", Tone.Green)
                pullRequestState == "CLOSED" -> JobBadge("PR closed", Tone.Gray)
                reviewDecision == "CHANGES_REQUESTED" -> JobBadge("Needs input", Tone.Orange)
                published != null || pullRequestState == "OPEN" -> JobBadge("In review", Tone.Blue)
                else -> JobBadge("Ready", Tone.Green)
            }
            JobStatus.failed -> JobBadge("Failed", Tone.Red)
            JobStatus.stopped -> JobBadge("Stopped", Tone.Gray)
            JobStatus.interrupted -> JobBadge("Needs you", Tone.Orange)
        }
    }

    val verdictLine: String? get() {
        val review = reviewValue ?: return if (reviewing == null) null else "Oby is reviewing"
        val verdict = if (review.label == "Approved") "Oby approved" else "Oby requested changes"
        return if (review.round > 1) "$verdict (review ${review.round})" else verdict
    }

    /** Nothing more is to happen for it, so Clear done may take it (JobList.settled). */
    fun settled(): Boolean = !(isActive || waitingValue != null || needsYou)
    fun listed(after: Instant?): Boolean = !settled() || JobList.shows(finished, after)
    fun clearable(): Boolean = settled()

    /** The card's live line while it runs: "Work · Running swift test"; nil once it ended. */
    val liveLine: String? get() {
        if (!isActive) return null
        return listOf(stageNow ?: "", step).filter { it.isNotEmpty() }.joinToString(" · ").ifEmpty { null }
    }
    val stageNow: String? get() = stages.firstOrNull { it.state == "current" }?.title

    val outcome: JobOutcome? get() {
        val first = firstLine
        return when (st) {
            JobStatus.queued, JobStatus.running -> null
            JobStatus.stopped -> JobOutcome("Stopped", null, false)
            JobStatus.failed -> JobOutcome(first ?: "Failed", null, true)
            JobStatus.interrupted -> JobOutcome(reason ?: first ?: "Needs you", null, false)
            JobStatus.done -> {
                val url = PublishedLink.url(published)
                when {
                    url != null -> url.substringAfterLast('/').toIntOrNull()?.let { JobOutcome("Pull request #$it", url, false) } ?: JobOutcome("Published", url, false)
                    !publishError.isNullOrEmpty() -> JobOutcome("Not published: $publishError", null, true)
                    else -> JobOutcome(first ?: "Done", null, false)
                }
            }
        }
    }

    /** Its pull request as the page words it. */
    val pullRequestWords: String? get() {
        if (published == null) return null
        return when {
            pullRequestState == "MERGED" -> "Merged"
            pullRequestState == "CLOSED" -> "Closed"
            reviewDecision == "APPROVED" -> "Approved"
            reviewDecision == "CHANGES_REQUESTED" -> "Changes requested"
            else -> "Waiting for review"
        }
    }

    companion object {
        const val TRY_AGAIN = "Try again, picking up where you left off. Finish with a short summary as asked."
        fun waitingLine(text: String) = text.replaceFirstChar { it.uppercase() }
    }
}

data class JobOutcome(val text: String, val link: String?, val failed: Boolean)

enum class Tone { Blue, Green, Orange, Red, Gray }
data class JobBadge(val text: String, val tone: Tone)

object PublishedLink {
    /** A job's published address, only when it's a GitHub page over https. */
    fun url(published: String?): String? {
        val uri = published?.let { runCatching { java.net.URI(it) }.getOrNull() } ?: return null
        return if (uri.scheme == "https" && uri.host == "github.com") published else null
    }
}

@Serializable data class Account(
    val id: String, val agent: String = "claude", val name: String = "", val label: String? = null, val signedIn: Boolean = false,
    val fiveHour: Double? = null, val sevenDay: Double? = null, val fiveHourResets: Date? = null, val sevenDayResets: Date? = null,
    val running: Int = 0, val fullUntil: Date? = null, val tetrix: Boolean? = null, val tetrixJobs: Int? = null, val tetrixUsed: Int? = null,
    val reserved: Boolean? = null, val reserveLiftedUntil: Date? = null,
) {
    val usage get() = UsageSnapshot(agent, name, label, fiveHour, sevenDay, fiveHourResets, sevenDayResets, running, reserveLiftedUntil, signedIn)
}

@Serializable data class RunnerConfirm(val action: String = "", val target: String = "", val payload: Map<String, String>? = null) {
    val words: String? get() = InboxWords.plain(payload?.get("words")) ?: InboxWords.plain(payload?.get("answer"))
    companion object { const val KIND = "confirm"; const val CONFIRM = "Confirm" }
}

@Serializable data class InboxItem(
    val kind: String, val id: String, val job: String = "", val title: String = "", val text: String = "",
    val options: List<String> = emptyList(), val details: List<String>? = null, val created: Date,
    val done: Date? = null, val later: Date? = null, val answer: String? = null,
    val headline: String? = null, val happened: String? = null, val recommended: Int? = null, val why: String? = null,
    val confirm: JsonElement? = null,
) {
    val confirmValue: RunnerConfirm? get() = confirm.lenient()
    val isOpen get() = done == null
    val words get() = InboxWords(headline, happened, recommended, why, confirmValue)
    fun waiting(now: Instant = Instant.now()) = done == null && (later?.let { it <= now } ?: true)

    fun line(now: Instant = Instant.now()): String {
        val label = when (kind) {
            "question" -> "Question"; "review" -> "Out of reviews"; "limit" -> "Out of usage"; "audit" -> "Issue audit"
            "merge" -> "Not merged"; "failure" -> "Oby failure"; "start" -> "Start it?"; "permission" -> "Permission"
            RunnerConfirm.KIND -> "Confirm it?"; else -> "Failed"
        }
        return "$label · $title · ${Elapsed.waiting(created, now)}"
    }

    companion object {
        fun waiting(items: List<InboxItem>, now: Instant = Instant.now()) = items.filter { it.waiting(now) }.sortedBy { it.created }
    }
}

data class InboxWords(val headline: String?, val happened: String?, val recommended: Int?, val why: String?, val confirm: RunnerConfirm?) {
    fun title(text: String) = plain(headline) ?: text
    val body: String? get() = plain(happened)
    fun details(text: String): String? = if (plain(headline) == null) null else plain(text)

    companion object {
        fun plain(words: String?): String? = words?.trim()?.takeIf { it.isNotEmpty() }
    }
}

@Serializable data class ModelChoice(val model: String, val effort: String, val complexEffort: String? = null) {
    companion object {
        fun effortName(effort: String) = if (effort == "xhigh") "Extra high" else effort.replaceFirstChar { it.uppercase() }
        fun name(model: String) = mapOf(
            "claude-opus-5-5" to "Opus 5.5", "claude-sonnet-5-5" to "Sonnet 5.5", "claude-haiku-5-5" to "Haiku 5.5",
            "claude-fable-5-1" to "Fable 5.1", "gpt-6-astra" to "GPT-6-Astra", "auto" to "Auto",
        )[model] ?: model
    }
}

@Serializable data class CursorModelChoice(val model: String)
@Serializable data class ModelSettings(val claude: ModelChoice, val codex: ModelChoice, val cursor: CursorModelChoice? = null)

@Serializable data class ModelOptions(val claude: Tool, val codex: Tool, val cursor: Tool? = null) {
    @Serializable data class Model(val id: String, val name: String, val efforts: List<String>? = null)
    @Serializable data class Tool(val models: List<Model> = emptyList(), val efforts: List<String>? = null, val complexEfforts: List<String>? = null)
}

@Serializable data class RunnerStatus(
    val runner: Info, val accounts: List<Account> = emptyList(), val models: ModelSettings? = null, val clearedAt: Date? = null,
    val permissions: Permissions? = null,
) {
    @Serializable data class Info(val version: String = "", val host: String = "")
    @Serializable data class Permissions(val mode: String? = null)
}

@Serializable data class ClearedAt(val clearedAt: Date)
@Serializable data class StoppedJobs(val stopped: Int = 0, val jobs: List<Job> = emptyList())

enum class Who { user, oby }

/** One turn of the conversation with Oby. */
data class Turn(
    val id: String = java.util.UUID.randomUUID().toString().lowercase(),
    val date: Instant = Instant.now(),
    val who: Who,
    val text: String,
    val jobs: List<String>? = null,
    val voice: Boolean? = null,
    val details: String? = null,
    val conversation: String? = null,
)

/** A turn as `GET /v1/conversation` and the `turn` event send it. */
@Serializable data class RunnerTurn(
    val id: String, val who: String, val text: String = "", val at: Date, val jobs: List<String>? = null, val details: String? = null,
    val conversation: String? = null, val artifacts: JsonElement? = null, val ended: Boolean? = null,
) {
    val extras get() = TurnExtras(artifacts.lenient<List<ArtifactRef>>().orEmpty(), ended == true)
    val turn get() = Turn(id, at, if (who == "user") Who.user else Who.oby, text, jobs?.takeIf { it.isNotEmpty() }, details = details, conversation = conversation)
}

data class TurnExtras(val artifacts: List<ArtifactRef> = emptyList(), val ended: Boolean = false)

enum class StepState { running, done, failed }

@Serializable data class TurnStep(
    val turn: String, val index: Int, val action: String? = null, val text: String = "", val state: String = "done",
    val at: Date? = null, val conversation: String? = null, val tool: String? = null, val detail: String? = null,
) {
    val stepState get() = when (state) { "running" -> StepState.running; "failed" -> StepState.failed; else -> StepState.done }
    val id get() = "$turn#$index"
    fun with(state: StepState) = copy(state = state.name)
}

@Serializable data class TurnDelta(val conversation: String? = null, val turn: String, val text: String)

@Serializable data class RunnerConversation(
    val id: String, val title: String = "", val pinned: Boolean = false, val created: Date? = null, val lastActivity: Date? = null,
    val deleted: Boolean = false, val turn: Match? = null,
) {
    @Serializable data class Match(val who: String? = null, val text: String = "")
    val latest: Instant get() = lastActivity ?: created ?: Instant.EPOCH
}

@Serializable data class RunnerArtifact(
    val id: String, val title: String = "", val kind: String = "", val conversation: String? = null, val job: String? = null,
    val versions: List<Version> = emptyList(),
) {
    @Serializable data class Version(val version: Int, val files: List<String> = emptyList())
    fun files(version: Int) = versions.firstOrNull { it.version == version }?.files.orEmpty()
    val kindName get() = mapOf("html" to "Page", "markdown" to "Document", "image" to "Image", "pdf" to "PDF", "canvas" to "Canvas")[kind]
        ?: kind.replaceFirstChar { it.uppercase() }
    fun line(version: Int?, agent: String?): String {
        val maker = if (job == null) "Oby" else agent ?: "a task"
        return listOfNotNull(kindName, version?.let { "v$it" }, "made by $maker").filter { it.isNotEmpty() }.joinToString(" · ")
    }
}

@Serializable data class ArtifactEvent(
    val id: String, val version: Int? = null, val title: String? = null, val kind: String? = null, val conversation: String? = null,
    val job: String? = null, val deleted: Boolean? = null,
)

/** What the brain made of the user's words (`POST /v1/plans`). */
sealed interface PlanResult {
    data class Asked(val said: String, val question: Question) : PlanResult
    data class Reply(val text: String, val started: List<Job>) : PlanResult
    data object Nothing : PlanResult
}

data class PlannedTurn(val result: PlanResult, val conversation: String?)

@Serializable data class RunnerRule(val id: String, val rule: String, val repo: String? = null, val decision: String = "allow")

@Serializable data class RunnerRoutine(
    val id: String, val name: String, val repo: String = "", val kind: String = "", val task: String = "", val `when`: String = "",
    val zone: String = "", val enabled: Boolean = true, val nextRun: Date? = null, val failuresInARow: Int? = null, val lastRun: Run? = null,
) {
    @Serializable data class Run(val outcome: String = "", val ended: String? = null)

    val repoName get() = repo.substringAfterLast('/')

    fun about(now: Instant = Instant.now()): String {
        val parts = mutableListOf("$`when` · $repoName")
        val next = nextRun
        parts += if (next != null && enabled) "Next " + day(next, now) else "Paused"
        lastRun?.let { last ->
            parts += when {
                last.outcome == "started" && last.ended == null -> "Running now"
                last.outcome == "started" && last.ended == "done" -> "Last run done"
                last.outcome == "started" && last.ended == "failed" -> "Last run failed"
                last.outcome == "started" -> "Last run ${last.ended}"
                last.outcome == "skipped" -> "Last run skipped"
                last.outcome == "missed" -> "Missed a run"
                else -> "Last run couldn't start"
            }
        }
        return parts.joinToString(" · ")
    }

    fun starts(now: Instant = Instant.now()): String? = if (enabled && nextRun != null) "Starts " + day(nextRun, now) else null

    companion object {
        fun upcoming(routines: List<RunnerRoutine>) = routines.filter { it.enabled && it.nextRun != null }.sortedBy { it.nextRun }
        fun day(date: Instant, now: Instant = Instant.now()): String {
            val zone = java.time.ZoneId.systemDefault()
            val d = date.atZone(zone).toLocalDate()
            val today = now.atZone(zone).toLocalDate()
            val time = Format.time(date)
            return when {
                d == today -> "today at $time"
                d == today.plusDays(1) -> "tomorrow at $time"
                java.time.Duration.between(now, date).toHours() < 6 * 24 -> "${Format.weekday(date)} at $time"
                else -> "${Format.monthDay(date)} at $time"
            }
        }
    }
}

@Serializable data class ResearchDocument(val job: String = "", val commit: String = "", val markdown: String = "", val proposals: List<ResearchProposal> = emptyList())
@Serializable data class ResearchProposal(val index: Int, val repo: String = "", val title: String = "", val body: String = "", val labels: List<String> = emptyList(), val filed: String? = null)
@Serializable data class FileProposalResult(val issue: String = "", val jobId: String? = null)

/** What a job's agent did with Tetrix through obid (`tetrix` on a job). Plain text throughout. */
@Serializable data class TetrixJobReport(
    val connected: Boolean? = null, val calls: Map<String, Int> = emptyMap(), val context: Boolean? = null,
    val saved: List<String> = emptyList(), val gaps: Gaps? = null,
) {
    @Serializable data class Gaps(
        val noResults: List<String> = emptyList(), val missing: List<String> = emptyList(), val unknownFiles: List<String> = emptyList(),
        val failed: List<Failure> = emptyList(), val sent: Date? = null, val session: String? = null, val notSent: String? = null,
    ) {
        @Serializable data class Failure(val tool: String = "", val error: String = "")
        val isEmpty get() = noResults.isEmpty() && missing.isEmpty() && unknownFiles.isEmpty() && failed.isEmpty()
        val lines get() = noResults.map { "No results: $it" } + missing.map { "Not in the graph: $it" } +
            unknownFiles.map { "A file it didn't know: $it" } + failed.map { "${it.tool} failed: ${it.error}" }
        val sentLine: String? get() = when {
            notSent != null -> "Not sent to Tetrix: $notSent"
            sent == null -> null
            else -> "Sent to Tetrix" + (session?.let { " as session $it" } ?: "")
        }
    }

    val isEmpty get() = calls.isEmpty() && saved.isEmpty() && context != true && (gaps?.isEmpty ?: true)
    val callsLine: String get() {
        val total = calls.values.sum()
        if (total <= 0) return if (connected == true) "Had Tetrix, but didn't ask it anything" else "Didn't ask Tetrix"
        val tools = calls.entries.sortedWith(compareByDescending<Map.Entry<String, Int>> { it.value }.thenBy { it.key }).map { "${it.key} ${it.value}" }
        return "Asked Tetrix ${if (total == 1) "once" else "$total times"}: " + tools.joinToString(", ")
    }

    companion object {
        fun accountLine(connected: Boolean, jobs: Int, used: Int, there: String): String {
            if (!connected) return "Tetrix: not connected: connect it $there"
            return if (jobs > 0) "Tetrix: used in $used of $jobs job${if (jobs == 1) "" else "s"}" else "Tetrix: connected"
        }
    }
}
