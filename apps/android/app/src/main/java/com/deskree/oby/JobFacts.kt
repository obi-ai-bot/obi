package com.deskree.oby

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.time.Duration
import java.time.Instant

// The job page's facts (#739) and the job's session (#755, #784), as apps/shared/JobPage.swift reads
// them. Every one is optional: absent means this obid doesn't serve it yet, and its part of the page hides.

@Serializable data class ToolCounts(
    val read: Int? = null, val search: Int? = null, val edit: Int? = null, val command: Int? = null, val test: Int? = null,
    val tetrix: Int? = null, val web: Int? = null, val mcp: Int? = null,
) {
    val chips: List<Pair<Int, String>> get() = listOf(
        Triple(read, "read", "read"), Triple(search, "search", "searches"), Triple(edit, "edit", "edits"),
        Triple(command, "command", "commands"), Triple(test, "test run", "test runs"), Triple(tetrix, "Tetrix", "Tetrix"),
        Triple(web, "web", "web"), Triple(mcp, "MCP", "MCP"),
    ).mapNotNull { (count, one, many) -> count?.takeIf { it > 0 }?.let { it to if (it == 1) one else many } }
    val line: String? get() = chips.takeIf { it.isNotEmpty() }?.joinToString(" · ") { "${it.first} ${it.second}" }
}

@Serializable data class LineDiff(val added: Int? = null, val removed: Int? = null)

@Serializable data class JobTool(val tool: String? = null, val kind: String? = null, val summary: String = "", val state: String? = null,
                                 val started: Date? = null, val seconds: Double? = null) {
    val running get() = state == "running"
    val failed get() = state == "failed"
}

@Serializable data class ActivityGroup(
    val id: String, val title: String = "", val state: String? = null, val started: Date? = null, val finished: Date? = null,
    val counts: ToolCounts? = null, val files: List<String>? = null, val diff: LineDiff? = null, val tools: List<JobTool>? = null,
) {
    val running get() = state == "running"
    val failed get() = state == "failed"
}

@Serializable data class JobActivity(val counts: ToolCounts? = null, val groups: List<ActivityGroup>? = null)

@Serializable data class JobUsage(val input: Int? = null, val output: Int? = null, val cacheRead: Int? = null, val cacheWrite: Int? = null,
                                  val costUsd: Double? = null, val priced: String? = null) {
    val tokens: Int? get() = listOfNotNull(input, output, cacheRead, cacheWrite).takeIf { it.isNotEmpty() }?.sum()
}

@Serializable data class WindowShare(val fiveHour: Double? = null, val sevenDay: Double? = null, val estimate: Boolean? = null)
@Serializable data class Span(val low: Double, val high: Double)
@Serializable data class JobEstimate(val low: Double, val high: Double, val basis: String? = null, val samples: Int? = null, val firstGiven: Span? = null)
data class StageTiming(val started: Instant? = null, val finished: Instant? = null, val waited: Double? = null, val estimate: Span? = null)
@Serializable data class TestCount(val passed: Int? = null, val failed: Int? = null, val total: Int? = null)

@Serializable data class CheckStep(val command: String, val passed: Boolean? = null, val seconds: Double? = null, val running: Boolean? = null,
                                   val tests: TestCount? = null) {
    val result: String? get() {
        val passedTests = tests?.passed
        if (tests != null && passedTests != null) {
            if (running == true) return tests.total?.let { "$passedTests of $it" } ?: "$passedTests passed"
            val failed = tests.failed
            if (failed != null && failed > 0) return "$passedTests passed, $failed failed"
            return "$passedTests passed"
        }
        if (running == true) return null
        return passed?.let { if (it) "passed" else "failed" }
    }
    val progress: Double? get() {
        val p = tests?.passed ?: return null
        val t = tests.total ?: return null
        return if (running == true && t > 0) minOf(1.0, p.toDouble() / t) else null
    }
}

@Serializable data class FailingTest(val test: String, val message: String? = null)
@Serializable data class CheckRound(val round: Int? = null, val steps: List<CheckStep> = emptyList(), val failing: List<FailingTest>? = null)

@Serializable data class JobScan(val ran: Boolean? = null, val clean: Boolean? = null, val commits: Int? = null, val files: Int? = null,
                                 val seconds: Double? = null, val reason: String? = null, val findings: List<Finding>? = null) {
    @Serializable data class Finding(val file: String = "", val line: Int? = null, val rule: String? = null)
}

@Serializable data class JobDiff(val files: Int? = null, val added: Int? = null, val removed: Int? = null)

data class JobFacts(
    val activity: JobActivity? = null, val usage: JobUsage? = null, val windowShare: WindowShare? = null, val estimate: JobEstimate? = null,
    val checks: List<CheckRound>? = null, val scan: JobScan? = null, val diff: JobDiff? = null, val context: String? = null,
    val stages: Map<String, StageTiming> = emptyMap(),
) {
    val waited: Double get() = stages.values.mapNotNull { it.waited }.sum()

    companion object {
        fun of(job: Job): JobFacts {
            val stages = job.stages.mapNotNull { s ->
                val timing = StageTiming(s.started.lenient<String>()?.let(::parseInstant), s.finished.lenient<String>()?.let(::parseInstant),
                                         s.waited.lenient(), s.estimate.lenient())
                if (timing == StageTiming()) null else s.id to timing
            }.toMap()
            return JobFacts(job.activity.lenient(), job.usage.lenient(), job.windowShare.lenient(), job.estimate.lenient(),
                            job.checks.lenient(), job.scan.lenient(), job.diff.lenient(), job.context.lenient(), stages)
        }
    }
}

/** How the page says times, counts and money. */
object JobPageText {
    fun took(seconds: Double): String {
        val s = maxOf(0.0, seconds)
        if (s < 10) return "${Math.round(s * 10) / 10.0}s".replace(".0s", "s")
        if (s < 60) return "${Math.round(s)}s"
        val whole = Math.round(s).toInt()
        return "${whole / 60}m ${whole % 60}s"
    }

    fun seconds(value: Double): String {
        val total = maxOf(0, Math.round(value).toInt())
        if (total < 60) return "${total}s"
        if (total < 300) return if (total % 60 == 0) "${total / 60}m" else "${total / 60}m ${total % 60}s"
        return minutes(value)
    }

    fun minutes(value: Double): String {
        val total = maxOf(0, Math.round(value).toInt())
        if (total < 60) return "${total}s"
        val minutes = (total + 30) / 60
        return if (minutes < 60) "${minutes}m" else "${minutes / 60}h ${minutes % 60}m"
    }

    fun range(low: Double, high: Double): String {
        val lo = maxOf(0.0, low); val hi = maxOf(lo, high)
        if (hi < 60) return pair(Math.round(lo).toInt(), Math.round(hi).toInt(), "s")
        if (hi < 5400) return pair(maxOf(1, Math.round(lo / 60).toInt()), maxOf(1, Math.ceil(hi / 60).toInt()), "m")
        return pair(maxOf(1, Math.floor(lo / 3600).toInt()), Math.ceil(hi / 3600).toInt(), "h")
    }

    private fun pair(low: Int, high: Int, unit: String) = if (low >= high) "$high$unit" else "$low–$high$unit"

    fun tokens(count: Int): String = when {
        count < 1000 -> "$count"
        count < 1_000_000 -> "${Math.round(count / 1000.0)}k"
        else -> (count / 1_000_000.0).let { if (it < 10) String.format(java.util.Locale.US, "%.1fM", it) else "${Math.round(it)}M" }
    }

    fun dollars(amount: Double) = String.format(java.util.Locale.US, "$%.2f", amount)
    fun percent(points: Double) = if (points > 0 && points < 1) "<1%" else "${Math.round(points)}%"
}

/** The job's clock on the page: how long it has worked (time waiting on you left out). */
data class JobClock(val phase: Phase, val elapsed: Double, val estimate: JobEstimate?) {
    enum class Phase { Working, Planning, Paused, Ended, Done }
    data class Track(val done: Double, val rangeStart: Double, val rangeEnd: Double, val paused: Boolean, val unknown: Boolean)

    val remaining: Span? get() {
        val e = estimate ?: return null
        return if (e.high > elapsed) Span(maxOf(0.0, e.low - elapsed), e.high - elapsed) else null
    }

    val track: Track? get() {
        val e = estimate ?: return null
        if (phase == Phase.Ended || phase == Phase.Done) return null
        val scale = maxOf(e.high / 0.8, elapsed / 0.9, 1.0)
        return Track(minOf(1.0, elapsed / scale), minOf(1.0, e.low / scale), minOf(1.0, e.high / scale), phase == Phase.Paused, phase == Phase.Planning)
    }

    fun aside(compact: Boolean): String? {
        val worked = JobPageText.minutes(elapsed)
        val usual = estimate?.let { JobPageText.range(it.low, it.high) }
        return when (phase) {
            Phase.Done -> null
            Phase.Ended -> if (compact) "Ran $worked" else usual?.let { "Ran $worked · jobs like this: $it" } ?: "Ran $worked"
            Phase.Planning -> if (usual == null) (if (compact) null else "$worked in") else if (compact) "Jobs like this: $usual" else "$worked in · jobs like this take $usual"
            Phase.Paused -> {
                val then = remaining?.let { JobPageText.range(it.low, it.high) }
                if (compact) then?.let { "Paused · then $it" } ?: "Paused" else "$worked in · paused" + (then?.let { " · then about $it" } ?: "")
            }
            Phase.Working -> {
                val left = remaining
                when {
                    left != null -> JobPageText.range(left.low, left.high).let { if (compact) "Done in about $it" else "$worked in · done in about $it" }
                    usual != null -> if (compact) "Past the usual $usual" else "$worked in · past the usual $usual"
                    else -> if (compact) null else "$worked in"
                }
            }
        }
    }

    val took: String get() {
        val given = estimate?.let { it.firstGiven ?: Span(it.low, it.high) }
        return "Took ${JobPageText.minutes(elapsed)}" + (given?.let { " · estimated ${JobPageText.range(it.low, it.high)}" } ?: "")
    }

    companion object {
        fun of(job: Job, facts: JobFacts?, mode: String?, needs: Boolean, now: Instant): JobClock {
            val phase = when (job.st) {
                JobStatus.done -> Phase.Done
                JobStatus.failed, JobStatus.stopped, JobStatus.interrupted -> Phase.Ended
                else -> if (needs) Phase.Paused else if (mode == "plan") Phase.Planning else Phase.Working
            }
            val worked = Duration.between(job.started ?: job.created, job.finished ?: now).toMillis() / 1000.0 - (facts?.waited ?: 0.0)
            return JobClock(phase, maxOf(0.0, worked), facts?.estimate)
        }
    }
}

// The session (#755, #784).

@Serializable data class Todo(val text: String, val state: String? = null)

@Serializable data class TranscriptEntry(
    val n: Int, val at: Date? = null, val kind: String, val tool: String? = null, val summary: String? = null, val text: String? = null,
    val state: String? = null, val seconds: Double? = null, val exit: Int? = null, val added: Int? = null, val removed: Int? = null,
    val todos: List<Todo>? = null, val activity: String? = null, val file: String? = null, val answer: String? = null,
) {
    val words get() = text ?: summary ?: ""
    val running get() = state == "running"
    val failed get() = state == "failed" || state == "declined"

    val verbAndTarget: Pair<String, String?> get() {
        val words = summary ?: ""
        if (!file.isNullOrEmpty()) {
            for (target in listOf(file, file.substringAfterLast('/'))) {
                if (words.length > target.length && words.endsWith(target)) return words.dropLast(target.length).trim() to file
            }
        }
        if (Filter.of(this) == Filter.Commands) {
            val space = words.indexOf(' ')
            if (space >= 0) return words.substring(0, space) to words.substring(space + 1)
        }
        return words to null
    }

    val meta: String? get() = when {
        exit != null && exit != 0 -> "exit $exit"
        state == "declined" -> "declined"
        added != null || removed != null -> "+${added ?: 0} −${removed ?: 0}"
        else -> null
    }

    enum class Filter(val label: String) {
        All("All"), Said("Said"), Commands("Commands"), Edits("Edits"), Reads("Reads"), Tetrix("Tetrix"), Web("Web");

        fun takes(entry: TranscriptEntry): Boolean = when (this) {
            All -> entry.kind != "start"
            Said -> entry.kind in listOf("said", "thought", "you")
            else -> entry.kind == "tool" && of(entry) == this
        }

        companion object {
            fun of(entry: TranscriptEntry): Filter? {
                when (entry.activity) {
                    "command", "test" -> return Commands
                    "edit" -> return Edits
                    "read", "search" -> return Reads
                    "tetrix" -> return Tetrix
                    "web" -> return Web
                    null -> {}
                    else -> return null
                }
                val tool = (entry.tool ?: "").lowercase()
                return when {
                    "tetrix" in tool -> Tetrix
                    tool in listOf("bash", "shell", "command") -> Commands
                    tool in listOf("edit", "write", "multiedit", "notebookedit", "apply_patch") -> Edits
                    tool in listOf("read", "grep", "glob", "search", "ls") -> Reads
                    tool.startsWith("web") -> Web
                    else -> null
                }
            }
        }
    }
}

@Serializable data class TranscriptEvent(val job: String, val entry: JsonElement? = null, val n: Int? = null, val append: String? = null) {
    val entryValue: TranscriptEntry? get() = entry.lenient()
}

data class TranscriptPage(val entries: List<TranscriptEntry>, val next: Int? = null) {
    companion object {
        /** From `{next, entries: […]}`, or a bare list; a line that can't be read is skipped. */
        fun read(json: JsonElement): TranscriptPage = when (json) {
            is kotlinx.serialization.json.JsonArray -> TranscriptPage(json.mapNotNull { it.lenient<TranscriptEntry>() })
            is JsonObject -> TranscriptPage(
                (json["entries"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { it.lenient<TranscriptEntry>() }.orEmpty(),
                runCatching { json["next"]?.jsonPrimitive?.content?.toInt() }.getOrNull(),
            )
            else -> TranscriptPage(emptyList())
        }
    }
}

data class TranscriptDetail(val input: JsonObject? = null, val outputText: String? = null, val lines: Int? = null, val truncated: Boolean? = null,
                            val exit: Int? = null, val diff: List<Pair<String?, String>> = emptyList()) {
    val command: String? get() = (input?.get("command") ?: input?.get("cmd"))?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }
    val given: List<String> get() {
        val skipped = setOf("command", "cmd", "content", "old_string", "new_string", "new_source", "edits", "patch")
        return input?.keys?.sorted()?.filter { it !in skipped }?.map { "$it: ${input[it]?.let(::jsonText)}" }.orEmpty()
    }

    companion object {
        fun jsonText(e: JsonElement): String = runCatching { e.jsonPrimitive.content }.getOrElse { e.toString() }

        fun read(json: JsonElement): TranscriptDetail {
            val detail = (json as? JsonObject)?.get("detail") as? JsonObject ?: return TranscriptDetail()
            val output = detail["output"] as? JsonObject
            fun JsonObject.str(k: String) = (this[k])?.let { runCatching { it.jsonPrimitive.content }.getOrNull() }
            val diff = (detail["diff"] as? kotlinx.serialization.json.JsonArray)?.mapNotNull { f ->
                val o = f as? JsonObject ?: return@mapNotNull null
                val patch = o.str("patch") ?: return@mapNotNull null
                o.str("path") to patch
            }.orEmpty()
            return TranscriptDetail(detail["input"] as? JsonObject, output?.str("text"), output?.str("lines")?.toIntOrNull(),
                                    output?.str("truncated")?.toBooleanStrictOrNull(), output?.str("exit")?.toIntOrNull(), diff)
        }
    }
}
