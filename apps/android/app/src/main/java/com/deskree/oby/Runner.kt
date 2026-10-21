package com.deskree.oby

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import java.io.IOException
import java.net.URLEncoder
import java.time.Instant
import java.util.concurrent.TimeUnit

/** One thing the runner reports while the app is open (apps/shared/Runner.swift's RunnerEvent). */
sealed interface RunnerEvent {
    data object Connected : RunnerEvent
    data class JobChanged(val job: Job) : RunnerEvent
    data class Accounts(val accounts: List<Account>) : RunnerEvent
    data class Cleared(val at: Instant) : RunnerEvent
    data class Inbox(val item: InboxItem) : RunnerEvent
    data class TurnAdded(val turn: Turn, val extras: TurnExtras) : RunnerEvent
    data class Step(val step: TurnStep) : RunnerEvent
    data class ConversationChanged(val conversation: RunnerConversation) : RunnerEvent
    data class Delta(val delta: TurnDelta) : RunnerEvent
    data class Artifact(val event: ArtifactEvent) : RunnerEvent
    data object Routine : RunnerEvent
    data class GitHub(val work: GitHubWork) : RunnerEvent
    data class Transcript(val event: TranscriptEvent) : RunnerEvent
}

/** Turns Server-Sent Events lines into events. Unknown events and pings are skipped. */
class EventParser {
    private var name = ""
    private val data = StringBuilder()

    fun feed(raw: String): RunnerEvent? {
        val line = raw.removeSuffix("\r")
        if (line.isEmpty()) {
            val json = data.toString()
            val event = name
            name = ""; data.clear()
            return runCatching { parse(event, json) }.getOrNull()
        }
        if (line.startsWith("event:")) name = line.drop(6).trim()
        if (line.startsWith("data:")) { if (data.isNotEmpty()) data.append('\n'); data.append(line.drop(5).trim()) }
        return null
    }

    private fun parse(name: String, json: String): RunnerEvent? {
        if (name == "routine") return RunnerEvent.Routine
        if (json.isEmpty()) return null
        val element = wire.parseToJsonElement(json)
        return when (name) {
            "job" -> RunnerEvent.JobChanged(wire.decodeFromJsonElement(element))
            "accounts" -> RunnerEvent.Accounts(wire.decodeFromJsonElement(element))
            "clear" -> RunnerEvent.Cleared(wire.decodeFromJsonElement<ClearedAt>(element).clearedAt)
            "inbox" -> RunnerEvent.Inbox(wire.decodeFromJsonElement(element))
            "turn" -> wire.decodeFromJsonElement<RunnerTurn>(element).let { RunnerEvent.TurnAdded(it.turn, it.extras) }
            "step" -> RunnerEvent.Step(wire.decodeFromJsonElement(element))
            "conversation" -> RunnerEvent.ConversationChanged(wire.decodeFromJsonElement(element))
            "delta" -> RunnerEvent.Delta(wire.decodeFromJsonElement(element))
            "artifact" -> RunnerEvent.Artifact(wire.decodeFromJsonElement(element))
            "github" -> RunnerEvent.GitHub(GitHubWork.read(element))
            "transcript" -> RunnerEvent.Transcript(wire.decodeFromJsonElement(element))
            else -> null
        }
    }
}

/**
 * The runner, through the paired Mac's gateway (or a runner of the owner's own at its address).
 * Every request carries this phone's device token for the gateway, `Authorization: Bearer`.
 * `refused`: what a 401 means here (a paired phone's pairing ended).
 */
class Runner(val base: String, private val token: String?, private val refused: String? = null) {
    companion object {
        /** Nowhere: where a request goes with no Mac paired and no runner set, so a fresh phone talks to nobody. */
        const val NOWHERE = "http://127.0.0.1:9"
        const val PLAN_TIMEOUT = 120L

        /** Plain HTTP only to this phone itself or a home-network address: everything else is HTTPS. */
        private val localOnlyCleartext = Interceptor { chain ->
            val url = chain.request().url
            if (!url.isHttps && url.host != "127.0.0.1" && !GatewayEnvelope.isLocal(url.host)) {
                throw IOException("Oby talks to ${url.host} over HTTPS only.")
            }
            chain.proceed(chain.request())
        }

        val client: OkHttpClient = OkHttpClient.Builder()
            .addInterceptor(localOnlyCleartext)
            // A redirect would skip the interceptor: obid never sends one, as its own client follows none.
            .followRedirects(false)
            .followSslRedirects(false)
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(45, TimeUnit.SECONDS)
            .build()

        private val json = "application/json".toMediaType()

        fun enc(text: String): String = URLEncoder.encode(text, "UTF-8").replace("+", "%20")

        /** Redeeming a pairing invitation at a Mac's gateway (`POST /v1/pairing`, docs/runner-api.md). */
        suspend fun redeem(url: String, credential: String, name: String): PairingAnswer = withContext(Dispatchers.IO) {
            val body = buildJsonObject { put("credential", credential); put("name", name) }.toString()
            val request = Request.Builder().url(url.trimEnd('/') + "/v1/pairing").post(body.toRequestBody(json)).build()
            client.newBuilder().callTimeout(15, TimeUnit.SECONDS).build().newCall(request).execute().use { response ->
                val text = response.body.string()
                if (!response.isSuccessful) {
                    val said = runCatching { wire.parseToJsonElement(text).jsonObject["error"]?.jsonPrimitive?.content }.getOrNull()
                    throw RunnerError(said ?: "The Mac refused this pairing invitation.", response.code)
                }
                wire.decodeFromString(PairingAnswer.serializer(), text)
            }
        }
    }

    private fun url(path: String) = base.trimEnd('/') + "/" + path

    private fun request(method: String, path: String, body: String?): Request {
        val builder = Request.Builder().url(url(path))
        token?.let { builder.header("Authorization", "Bearer $it") }
        builder.method(method, body?.toRequestBody(json) ?: if (method == "GET" || method == "DELETE") null else "".toRequestBody(json))
        return builder.build()
    }

    private fun check(response: Response, text: String?) {
        if (response.isSuccessful) return
        if (response.code == 401 && refused != null) throw RunnerError(refused, 401)
        val problem = text?.let { runCatching { wire.parseToJsonElement(it).jsonObject["error"]?.jsonPrimitive?.content }.getOrNull() }
        if (problem != null) throw RunnerError(problem, response.code)
        throw RunnerError(if (response.code == 401) "The runner didn't let this device in." else "The runner answered ${response.code}.", response.code)
    }

    /** The answer's body, after its status is checked. */
    suspend fun send(method: String, path: String, body: String? = null, timeout: Long = 45): String = withContext(Dispatchers.IO) {
        val call = client.newBuilder().readTimeout(timeout, TimeUnit.SECONDS).callTimeout(timeout + 15, TimeUnit.SECONDS).build()
            .newCall(request(method, path, body))
        call.execute().use { response ->
            val text = response.body.string()
            check(response, text)
            text
        }
    }

    private suspend fun element(method: String, path: String, body: String? = null, timeout: Long = 45): JsonElement =
        wire.parseToJsonElement(send(method, path, body, timeout).ifEmpty { "{}" })

    private suspend inline fun <reified T> call(method: String, path: String, body: String? = null, timeout: Long = 45): T =
        wire.decodeFromJsonElement(element(method, path, body, timeout))

    /** `null` from a runner that doesn't know the path (404). */
    private suspend inline fun <T> orNull(work: () -> T): T? = try { work() } catch (e: RunnerError) { if (e.status == 404) null else throw e }

    suspend fun status(): RunnerStatus = call("GET", "v1/status")
    suspend fun jobs(): List<Job> = call("GET", "v1/jobs?limit=50")
    suspend fun job(id: String): Job = call("GET", "v1/jobs/$id")
    suspend fun stop(id: String): Job = call("POST", "v1/jobs/$id/stop")
    suspend fun stopAll(): StoppedJobs = call("POST", "v1/stop-all")
    suspend fun dismiss(id: String): Job = call("POST", "v1/jobs/$id/dismiss")
    suspend fun clear(): Instant = call<ClearedAt>("POST", "v1/clear").clearedAt
    suspend fun inbox(): List<InboxItem> = orNull { call<List<InboxItem>>("GET", "v1/inbox") } ?: emptyList()
    suspend fun startNow(id: String): Job = call("POST", "v1/jobs/$id/start")
    suspend fun report(id: String): ResearchDocument = call("GET", "v1/jobs/$id/report")
    suspend fun fileProposal(id: String, index: Int, start: Boolean): FileProposalResult =
        call("POST", "v1/jobs/$id/proposals/$index/file", buildJsonObject { put("start", start) }.toString())

    suspend fun gitHubWork(): GitHubWork? = orNull { GitHubWork.read(element("GET", "v1/github/work")) }
    suspend fun refreshGitHubWork(): GitHubWork = GitHubWork.read(element("POST", "v1/github/work/refresh", timeout = 150))
    suspend fun startGitHubWork(id: String): Job = call("POST", "v1/github/work/${enc(id)}/start")

    suspend fun transcript(id: String, after: Int?): TranscriptPage =
        TranscriptPage.read(element("GET", "v1/jobs/$id/transcript" + (after?.let { "?after=$it" } ?: "")))
    suspend fun transcriptDetail(id: String, n: Int): TranscriptDetail = TranscriptDetail.read(element("GET", "v1/jobs/$id/transcript/$n"))

    suspend fun settle(id: String, answer: String? = null, done: Boolean? = null, later: Instant? = null): InboxItem =
        call("POST", "v1/inbox/$id/answer", buildJsonObject {
            answer?.let { put("answer", it) }; done?.let { put("done", it) }; later?.let { put("later", it.toString()) }
        }.toString())

    suspend fun move(id: String, agent: String?, account: String?, model: String?): Job =
        call("POST", "v1/jobs/$id/move", buildJsonObject {
            agent?.let { put("agent", it) }; account?.let { put("account", it) }; model?.let { put("model", it) }
        }.toString())

    suspend fun liftReserve(id: String, lift: Boolean): Account = call("POST", "v1/accounts/$id/reserve", buildJsonObject { put("lift", lift) }.toString())
    suspend fun tell(id: String, text: String): Job = call("POST", "v1/jobs/$id/messages", buildJsonObject { put("text", text) }.toString())
    suspend fun modelOptions(): ModelOptions = call("GET", "v1/settings/models/options")
    suspend fun setModels(models: ModelSettings): ModelSettings =
        call("PUT", "v1/settings/models", wire.encodeToString(ModelSettings.serializer(), models))

    /** `POST /v1/plans`: `conversation` names the one the words join, `new` starts one; `id` is the echo's. */
    suspend fun planned(said: String, answer: Pair<String, String>?, conversation: String?, new: Boolean, id: String?): PlannedTurn {
        val body = buildJsonObject {
            put("said", said)
            answer?.let { put("answer", buildJsonObject { put("question", it.first); put("option", it.second) }) }
            put("attachments", kotlinx.serialization.json.JsonArray(emptyList()))
            conversation?.let { put("conversation", it) }
            if (new) put("new", true)
            id?.let { put("id", it) }
        }
        val o = element("POST", "v1/plans", body.toString(), PLAN_TIMEOUT).jsonObject
        val kind = o["kind"]?.jsonPrimitive?.content
        val result = when (kind) {
            "question" -> PlanResult.Asked(o["said"]?.jsonPrimitive?.content.orEmpty(), wire.decodeFromJsonElement(o["question"]!!))
            "reply", "plan" -> PlanResult.Reply(o["text"]?.jsonPrimitive?.content.orEmpty(),
                                                o["jobs"]?.lenient<List<Job>>().orEmpty())
            else -> PlanResult.Nothing
        }
        return PlannedTurn(result, runCatching { o["conversation"]?.jsonPrimitive?.content }.getOrNull())
    }

    suspend fun routines(): List<RunnerRoutine>? = orNull { call<List<RunnerRoutine>>("GET", "v1/routines") }
    suspend fun setRoutine(id: String, enabled: Boolean): RunnerRoutine = call("PATCH", "v1/routines/$id", buildJsonObject { put("enabled", enabled) }.toString())
    suspend fun runRoutine(id: String) { send("POST", "v1/routines/$id/run") }
    suspend fun deleteRoutine(id: String) { send("DELETE", "v1/routines/$id") }

    suspend fun conversations(query: String? = null, limit: Int = 100): List<RunnerConversation>? = orNull {
        call<List<RunnerConversation>>("GET", "v1/conversations?limit=$limit" + (query?.let { "&q=${enc(it)}" } ?: ""))
    }
    suspend fun updateConversation(id: String, title: String? = null, pinned: Boolean? = null): RunnerConversation =
        call("PATCH", "v1/conversations/$id", buildJsonObject { title?.let { put("title", it) }; pinned?.let { put("pinned", it) } }.toString())
    suspend fun deleteConversation(id: String) { send("DELETE", "v1/conversations/$id") }
    suspend fun stopConversation(conversation: String?) {
        send("POST", "v1/conversation/stop", conversation?.let { buildJsonObject { put("conversation", it) }.toString() })
    }

    suspend fun conversationTurns(id: String?, before: String?, limit: Int = 50): List<RunnerTurn> {
        var query = "limit=$limit"
        id?.let { query += "&id=${enc(it)}" }
        before?.let { query += "&before=${enc(it)}" }
        return try { call("GET", "v1/conversation?$query") } catch (e: RunnerError) { if (e.status == 404 && before == null) emptyList() else throw e }
    }

    suspend fun artifact(id: String): RunnerArtifact? = orNull { call<RunnerArtifact>("GET", "v1/artifacts/${enc(id)}") }

    /** One file of an artifact's version, with obid's answer as it is: its status and headers, the CSP among them. */
    fun artifactFile(ref: ArtifactRef, path: String): Response {
        val segments = (listOf(ref.id, ref.version.toString()) + path.split("/")).joinToString("/") { enc(it) }
        return client.newCall(request("GET", "v1/artifacts/$segments", null)).execute()
    }

    suspend fun setMode(id: String, mode: RunnerMode): Job = call("POST", "v1/jobs/$id/mode", buildJsonObject { put("mode", mode.name) }.toString())
    suspend fun answer(job: String, permission: String, decision: String, message: String? = null): Job =
        call("POST", "v1/jobs/$job/permission", buildJsonObject { put("id", permission); put("decision", decision); message?.let { put("message", it) } }.toString())
    suspend fun setDefaultMode(mode: RunnerMode) { send("PUT", "v1/settings/permissions", buildJsonObject { put("mode", mode.name) }.toString()) }
    suspend fun permissionRules(): List<RunnerRule> = call("GET", "v1/permissions/rules")
    suspend fun removeRule(id: String) { send("DELETE", "v1/permissions/rules/$id") }

    suspend fun publishAction(id: String): String = element("GET", "v1/jobs/$id/publish").jsonObject["action"]!!.jsonPrimitive.content
    suspend fun publish(id: String, approval: Approval): String =
        element("POST", "v1/jobs/$id/publish", wire.encodeToString(Approval.serializer(), approval)).jsonObject["url"]!!.jsonPrimitive.content

    suspend fun register(name: String, publicKey: String): String =
        element("POST", "v1/devices", buildJsonObject { put("name", name); put("publicKey", publicKey) }.toString()).jsonObject["id"]!!.jsonPrimitive.content

    /** Hands the runner this phone's FCM token, for alerts when a job needs you. Answers whether the runner pushes. */
    suspend fun registerNotifications(token: String): Boolean =
        element("POST", "v1/notifications", buildJsonObject {
            put("token", token); put("platform", "fcm"); put("topic", BuildConfig.APPLICATION_ID)
        }.toString()).jsonObject["push"]?.jsonPrimitive?.content == "true"

    /** Server-Sent Events until the connection drops; the caller reconnects. Split on `\n` only. */
    fun events(): Flow<RunnerEvent> = callbackFlow {
        val stream = client.newBuilder().readTimeout(0, TimeUnit.SECONDS).build()
        val request = request("GET", "v1/events", null).newBuilder().header("Accept", "text/event-stream").build()
        val call = stream.newCall(request)
        val reader = Thread {
            try {
                call.execute().use { response ->
                    check(response, if (response.isSuccessful) null else response.body.string())
                    trySend(RunnerEvent.Connected)
                    val source = response.body.source()
                    val parser = EventParser()
                    while (true) {
                        val line = source.readUtf8Line() ?: break
                        parser.feed(line)?.let { trySend(it) }
                    }
                }
                close()
            } catch (e: Exception) {
                close(e)
            }
        }
        reader.start()
        awaitClose { call.cancel() }
    }.flowOn(Dispatchers.IO)
}

@Serializable data class PairingAnswer(val token: String, val link: MacLink? = null, val expiresAt: Date? = null)

/** A device's approval for one publish, as the runner checks it (docs/runner-api.md). */
@Serializable data class Approval(val device: String, val action: String, val signedAt: String, val signature: String) {
    companion object {
        fun message(job: String, action: String, signedAt: String) = "oby-publish\n$job\n$action\n$signedAt".toByteArray()
    }
}

/** Your work on GitHub as obid finds it with its gh (docs/runner-api.md, "obid only: GitHub work"). */
data class GitHubWork(val signedIn: Boolean, val login: String? = null, val items: List<Item> = emptyList(), val error: String? = null,
                      val checkedAt: Instant? = null, val counts: Map<String, Int> = emptyMap()) {
    @Serializable data class Board(val project: String? = null, val column: String? = null)

    @Serializable data class Item(
        val id: String, val list: String, val repo: String, val number: Int, val title: String, val url: String, val author: String? = null,
        val updated: Date? = null, val draft: Boolean? = null, val reviewDecision: String? = null, val checks: String? = null,
        val known: Boolean = true, val job: String? = null, val board: JsonElement? = null,
    ) {
        val type: WorkType get() = if (list == "assigned") WorkType.Issues else WorkType.Review
        val repoName get() = repo.substringAfterLast('/')
        val who: String? get() = if (list == "reviews") author?.let(::plain) else null
        val heading get() = "#$number ${plain(title)}"
        val headline: String get() = when (list) {
            "reviews" -> "${author?.let(::plain) ?: "Someone"} asked you to review $repoName #$number."
            "assigned" -> "Assigned to you in $repoName #$number."
            else -> state ?: "Open in $repoName #$number."
        }
        val action: String? get() = if (!known || draft == true) null else when (list) { "reviews" -> "Review it"; "assigned" -> "Fix it"; else -> null }
        val label get() = if (action == null) (if (list == "mine") "Your pull request" else "On GitHub") else "Start it?"
        val state: String? get() {
            val review = when (reviewDecision) { "APPROVED" -> "Approved"; "CHANGES_REQUESTED" -> "Changes requested"; "REVIEW_REQUIRED" -> "Waiting for review"; else -> null }
            val checksLine = when (checks) { "SUCCESS" -> "checks passed"; "FAILURE", "ERROR" -> "checks failed"; "PENDING", "EXPECTED" -> "checks running"; else -> null }
            val line = listOfNotNull(review, checksLine).joinToString(", ")
            return if (line.isEmpty()) null else line.replaceFirstChar { it.uppercase() } + "."
        }
        val note: String? get() = when {
            list == "mine" -> null
            !known -> "Oby doesn't work in $repo yet: add it to repos in obid's configuration."
            draft == true -> "It's a draft: Oby can review it once it's ready for review."
            else -> null
        }
        private val boardValue: Board? get() = board.lenient()
        val column: String? get() = boardValue?.column?.let(::plain)?.takeIf { it.isNotEmpty() }
        val project: String? get() = if (column == null) null else boardValue?.project?.let(::plain)
        val page: String? get() = page(url)
    }

    data class Column(val name: String?, val project: String?, val items: List<Item>) {
        val id get() = "${project ?: ""}\u001F${name ?: ""}"
        companion object {
            fun rank(name: String?): Int = if (name == null) 5 else listOf("in progress", "in review", "todo", "backlog").indexOf(name.lowercase()).let { if (it < 0) 4 else it }
        }
    }

    fun cut(kind: WorkType): List<String> {
        val lists = when (kind) {
            WorkType.Review -> listOf("reviews" to "pull requests waiting for your review", "mine" to "your open pull requests")
            WorkType.Issues -> listOf("assigned" to "issues assigned to you")
            else -> emptyList()
        }
        return lists.mapNotNull { (list, what) ->
            val shown = items.count { it.list == list }
            val found = counts[list] ?: return@mapNotNull null
            if (found > shown) "The latest $shown of $found $what. The rest are on GitHub." else null
        }
    }

    fun waiting(kind: WorkType, later: Set<String>) =
        items.filter { it.type == kind && it.job == null && it.id !in later }.sortedByDescending { it.updated ?: Instant.EPOCH }

    fun toDo(kind: WorkType, later: Set<String>): List<Column> {
        val columns = mutableListOf<Column>()
        for (item in waiting(kind, later)) {
            val at = columns.indexOfFirst { it.name == item.column && it.project == item.project }
            if (at >= 0) columns[at] = columns[at].copy(items = columns[at].items + item) else columns += Column(item.column, item.project, listOf(item))
        }
        return columns.sortedWith(compareBy({ Column.rank(it.name) }, { it.name?.lowercase() ?: "" }, { it.project ?: "" }))
    }

    companion object {
        fun read(element: JsonElement): GitHubWork {
            val o = element.jsonObject
            fun str(k: String) = runCatching { o[k]?.jsonPrimitive?.content }.getOrNull()?.takeIf { o[k] !is kotlinx.serialization.json.JsonNull }
            val counts = (o["counts"] as? JsonObject)?.mapNotNull { (k, v) -> runCatching { v.jsonPrimitive.content.toInt() }.getOrNull()?.let { k to it } }?.toMap().orEmpty()
            val items = listOf("reviews", "assigned", "mine").flatMap { key ->
                runCatching { o[key]?.jsonArray }.getOrNull()?.mapNotNull { it.lenient<Item>() }.orEmpty()
            }
            return GitHubWork(str("signedIn") == "true", str("login"), items, str("error"), str("checkedAt")?.let(::parseInstant), counts)
        }

        /** A GitHub page to open: `https://github.com/…` and nothing else. */
        fun page(string: String): String? {
            val uri = runCatching { java.net.URI(string) }.getOrNull() ?: return null
            return if (uri.scheme == "https" && uri.host?.lowercase() == "github.com" && uri.userInfo == null && uri.port == -1) string else null
        }

        /** Someone else's words as one plain line: no control characters, at most 200 characters. */
        fun plain(text: String): String {
            val line = text.map { if (it.isISOControl() || it == ' ' || it == ' ') ' ' else it }.joinToString("")
                .split(" ").filter { it.isNotEmpty() }.joinToString(" ")
            return if (line.length > 200) line.take(199) + "…" else line
        }

        /** What obid's answer does to the feed: one read before the current one doesn't replace it. */
        fun applied(answer: GitHubWork?, current: GitHubWork?): GitHubWork? {
            val read = answer?.checkedAt; val now = current?.checkedAt
            return if (read != null && now != null && read < now) current else answer
        }
    }
}
