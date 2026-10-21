package com.deskree.oby

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.time.Duration
import java.time.Instant

/**
 * The thread a conversation shows (apps/shared/ConversationModel.swift): the runner's turns, read
 * in pages and followed over its `turn` events, with Oby's steps and words under way, the artifacts
 * a turn made, and which turns a job added when it ended.
 */
class ConversationModel(var page: suspend (before: String?, limit: Int) -> List<Turn> = { _, _ -> emptyList() }) {
    data class Streamed(val text: String, val since: Instant)

    var runnerTurns by mutableStateOf(listOf<Turn>()); private set
    var hasOlder by mutableStateOf(false); private set
    var loading by mutableStateOf(false); private set
    var problem by mutableStateOf<String?>(null); private set
    var steps by mutableStateOf(mapOf<String, List<TurnStep>>()); private set
    private var latestStepTurn: String? = null
    private var generation = 0
    var arrived by mutableStateOf(mapOf<String, Instant>()); private set
    var streamed by mutableStateOf(mapOf<String, Streamed>()); private set
    private var refs by mutableStateOf(mapOf<String, List<ArtifactRef>>())
    private var ended = setOf<String>()
    var artifacts by mutableStateOf(mapOf<String, RunnerArtifact>()); private set
    var gone by mutableStateOf(setOf<String>()); private set
    var lookUp: suspend (String) -> RunnerArtifact? = { null }
    var time: () -> Instant = { Instant.now() }

    suspend fun reload(arriving: Boolean = false) {
        generation += 1
        val mine = generation
        loading = true
        try {
            val latest = page(null, PAGE)
            if (mine != generation) return
            if (arriving) latest.filter { t -> runnerTurns.none { it.id == t.id } }.forEach(::arrive)
            runnerTurns = ordered(latest)
            hasOlder = latest.size >= PAGE
            problem = null
            steps = settled(steps)
            streamed = streamed.filter { (id, _) ->
                val at = runnerTurns.indexOfFirst { it.id == id }
                at < 0 || runnerTurns.drop(at + 1).none(::answers)
            }
        } catch (e: Exception) {
            if (mine == generation) problem = e.message
        } finally {
            if (mine == generation) loading = false
        }
    }

    suspend fun loadOlder() {
        val oldest = runnerTurns.firstOrNull() ?: return
        if (!hasOlder || loading) return
        val mine = generation
        loading = true
        try {
            val older = page(oldest.id, PAGE)
            if (mine != generation) return
            runnerTurns = merged(older, runnerTurns)
            hasOlder = older.size >= PAGE
            problem = null
        } catch (e: Exception) {
            if (mine == generation) problem = e.message
        } finally {
            if (mine == generation) loading = false
        }
    }

    fun apply(turn: Turn, extras: TurnExtras = TurnExtras()) {
        if (extras.artifacts.isNotEmpty()) refs = refs + (turn.id to extras.artifacts)
        if (extras.ended) ended = ended + turn.id
        val new = runnerTurns.none { it.id == turn.id }
        if (new && answers(turn)) streamed.values.minOfOrNull { it.since }?.let { since ->
            streamed = emptyMap()
            if (turn.id !in arrived) arrived = arrived + (turn.id to since)
        }
        if (new) arrive(turn)
        runnerTurns = placed(turn, runnerTurns)
    }

    private fun answers(turn: Turn) = turn.who == Who.oby && turn.id !in ended
    fun endedTurn(turn: Turn) = turn.id in ended

    fun note(turns: List<RunnerTurn>) {
        for (turn in turns) {
            val list = turn.extras.artifacts
            if (list.isNotEmpty()) refs = refs + (turn.id to list)
            if (turn.ended == true) ended = ended + turn.id
        }
    }

    fun apply(delta: TurnDelta) {
        val now = streamed[delta.turn] ?: Streamed("", time())
        streamed = streamed + (delta.turn to now.copy(text = now.text + delta.text))
    }

    fun streamed(under: Turn, thread: List<Turn>): Streamed? {
        streamed[under.id]?.let { return it }
        if (under.who != Who.user || thread.any { it.id in streamed } || thread.lastOrNull { it.who == Who.user }?.id != under.id) return null
        return streamed.values.maxByOrNull { it.since }
    }

    fun artifactRefs(turn: Turn) = refs[turn.id].orEmpty()

    fun apply(event: ArtifactEvent) {
        if (event.deleted == true) {
            artifacts = artifacts - event.id
            gone = gone + event.id
            return
        }
        var artifact = artifacts[event.id] ?: RunnerArtifact(event.id, event.title ?: "", event.kind ?: "", event.conversation, event.job)
        event.title?.let { artifact = artifact.copy(title = it) }
        event.kind?.let { artifact = artifact.copy(kind = it) }
        event.version?.let { v -> if (artifact.versions.none { it.version == v }) artifact = artifact.copy(versions = artifact.versions + RunnerArtifact.Version(v)) }
        artifacts = artifacts + (event.id to artifact)
        gone = gone - event.id
    }

    suspend fun resolve(id: String) {
        if (id in artifacts || id in gone) return
        try {
            val found = lookUp(id)
            if (found != null) artifacts = artifacts + (id to found) else gone = gone + id
        } catch (_: Exception) {
            // Not now: the card says so, and the next look tries again.
        }
    }

    private fun arrive(turn: Turn) {
        val now = time()
        if (turn.who != Who.oby || turn.id in arrived || Duration.between(turn.date, now).abs().seconds >= 10) return
        arrived = arrived + (turn.id to now)
    }

    fun apply(step: TurnStep) {
        steps = steps + (step.turn to placed(step, steps[step.turn].orEmpty()))
        latestStepTurn = step.turn
    }

    fun settleSteps() { steps = settled(steps) }

    fun settleLatestSteps() {
        val latest = latestStepTurn ?: return
        val list = steps[latest] ?: return
        steps = steps + (latest to settled(list, StepState.done))
    }

    val working: Boolean get() = steps.values.any { list -> list.any { it.stepState == StepState.running } }

    fun forget() {
        generation += 1
        steps = emptyMap(); latestStepTurn = null; arrived = emptyMap(); streamed = emptyMap(); refs = emptyMap(); ended = emptySet()
        artifacts = emptyMap(); gone = emptySet(); runnerTurns = emptyList(); hasOlder = false; loading = false; problem = null
    }

    fun thread(local: List<Turn>) = merged(runnerTurns, local)

    fun steps(under: Turn, thread: List<Turn>): List<TurnStep> {
        steps[under.id]?.let { return it }
        val latest = latestStepTurn ?: return emptyList()
        if (under.who != Who.user || thread.any { it.id == latest } || thread.lastOrNull { it.who == Who.user }?.id != under.id) return emptyList()
        return steps[latest].orEmpty()
    }

    companion object {
        const val PAGE = 50

        fun ordered(turns: List<Turn>) = turns.withIndex().sortedWith(compareBy({ it.value.date }, { it.index })).map { it.value }

        fun merged(first: List<Turn>, second: List<Turn>): List<Turn> {
            val seen = mutableSetOf<String>()
            return ordered((first + second).filter { seen.add(it.id) })
        }

        fun placed(turn: Turn, list: List<Turn>): List<Turn> {
            val out = list.toMutableList()
            val at = out.indexOfFirst { it.id == turn.id }
            if (at >= 0) { out[at] = turn; return ordered(out) }
            val after = out.indexOfFirst { it.date > turn.date }
            out.add(if (after < 0) out.size else after, turn)
            return out
        }

        fun placed(step: TurnStep, list: List<TurnStep>): List<TurnStep> {
            val out = list.toMutableList()
            val at = out.indexOfFirst { it.index == step.index }
            if (at >= 0) out[at] = step else {
                val after = out.indexOfFirst { it.index > step.index }
                out.add(if (after < 0) out.size else after, step)
            }
            return out
        }

        fun settled(steps: Map<String, List<TurnStep>>) = steps.mapValues { settled(it.value) }
        fun settled(list: List<TurnStep>, state: StepState = StepState.failed) =
            list.map { if (it.stepState == StepState.running) it.with(state) else it }

        fun jobsOf(turn: Turn, jobs: List<Job>) = turn.jobs.orEmpty().mapNotNull { id -> jobs.firstOrNull { it.id == id } }
        fun missing(turn: Turn, jobs: List<Job>) = turn.jobs.orEmpty().filter { id -> jobs.none { it.id == id } }
        fun started(job: String, turns: List<Turn>) = turns.any { job in it.jobs.orEmpty() }
    }
}
