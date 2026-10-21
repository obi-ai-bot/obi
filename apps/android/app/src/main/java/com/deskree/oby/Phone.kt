package com.deskree.oby

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.provider.Settings
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job as Work
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * The phone's view of the runner (apps/ios/app/Phone.swift): its jobs and accounts, kept live while
 * the app is in front, the conversations, and the words that turn into a plan. One for the app.
 */
class Phone(val context: Context) {
    sealed interface Talk {
        data object None : Talk
        data class Thinking(val said: String) : Talk
        data class Queued(val said: String) : Talk
        data class Asked(val said: String, val question: Question) : Talk
        data class Reply(val text: String) : Talk
    }

    private data class Request(val said: String, val answer: Pair<String, String>?, val voice: Boolean, var conversation: String? = null, var new: Boolean = false)

    private val prefs = Store.prefs(context)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    val drafts = Drafts(prefs)
    private val offlineQueue = OfflineQueue(prefs)
    val voice = PhoneVoice(context)
    private val speaker = PhoneSpeaker(context)
    private val finder = MacFinder(context)
    val conversation = ConversationModel()

    /** The side panel, open on one of its sections, or null while it's closed. */
    var panel by mutableStateOf<PanelSection?>(null)
    /** The panel's groups folded away with their chevron (Sangam's Sidebar.tsx), kept while Oby runs. */
    var panelFolded by mutableStateOf(setOf<String>())
    /** What's open over Home: the app's one stack. */
    var homePath by mutableStateOf(listOf<Route>())
    /** The job whose notification's Publish was tapped; its page publishes once it's ready. */
    var publishing by mutableStateOf<String?>(null)

    var echoes by mutableStateOf(listOf<Turn>()); private set
    var failures by mutableStateOf(mapOf<String, String>()); private set
    private val requests = mutableMapOf<String, Request>()
    private var pending: String? = null

    var conversations by mutableStateOf<List<RunnerConversation>?>(null); private set
    var current by mutableStateOf<String?>(null); private set
    var startingNew by mutableStateOf(false); private set
    private var heldDeltas = mutableListOf<TurnDelta>()
    private var talkIn: String? = null
    var previews by mutableStateOf(mapOf<String, String>()); private set
    val since: Instant = Instant.now()
    var seen by mutableStateOf(setOf<String>()); private set
    fun markSeen(id: String) { seen = seen + id }

    var talk by mutableStateOf<Talk>(Talk.None)
    var connection by mutableStateOf<Connection>(Connection.Connecting); private set
    var lastSeen by mutableStateOf(prefs.getLong("runner.lastSeen", 0).takeIf { it > 0 }?.let(Instant::ofEpochMilli)); private set
    var host by mutableStateOf(""); private set
    var loaded by mutableStateOf(false); private set
    var gitHubWork by mutableStateOf<GitHubWork?>(null); private set
    var gitHubLater by mutableStateOf(setOf<String>())
    private var gitHubChanges = 0
    var liveSession: LiveSession? = null

    var jobs by mutableStateOf(listOf<Job>()); private set
    private var onScreen = mutableSetOf<String>()
    var accounts by mutableStateOf(listOf<Account>()); private set
    var routineChanges by mutableStateOf(0); private set
    var routines by mutableStateOf(listOf<RunnerRoutine>()); private set
    var inbox by mutableStateOf(listOf<InboxItem>()); private set
    var models by mutableStateOf<ModelSettings?>(null); private set
    var defaultMode by mutableStateOf<RunnerMode?>(null); private set
    var clearedAt by mutableStateOf<Instant?>(null); private set
    var online by mutableStateOf(true); private set
    var refusal by mutableStateOf<Int?>(null); private set
    var stopProblem by mutableStateOf<String?>(null); private set
    var pairedUntil by mutableStateOf(prefs.getLong("gateway.expiresAt", 0).takeIf { it > 0 }?.let(Instant::ofEpochMilli)); private set
    var archivedHere by mutableStateOf(prefs.getStringSet("phone.archived", emptySet()).orEmpty().toSet()); private set
    var speakReplies by mutableStateOf(prefs.getBoolean("voice.speakReplies", true)); private set
    /** The FCM token, once Firebase gave one; handed to the runner on every connection. */
    var pushToken by mutableStateOf<String?>(null)
    var pushes by mutableStateOf<Boolean?>(null); private set
    /** Asks whether Oby may alert you (the activity's runtime prompt): on connecting, and when words start a job. */
    var askNotifications: () -> Unit = {}

    private var loop: Work? = null
    private var planning: Work? = null
    private var spoken = false
    private var started = false
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /** A runner that isn't a paired Mac, at the address Connect › Another runner gives; null on a fresh phone. */
    var runnerURL by mutableStateOf(prefs.getString("runner.url", null)); private set
    /** The Mac this phone is linked to; null until pairing gives one. */
    var link by mutableStateOf<MacLink?>(null); private set
    /** The gateway's address on the local network while discovery sees the linked Mac; null away from home. */
    private var lan by mutableStateOf<String?>(null)

    init {
        val saved = prefs.getString("mac.link", null)
        if (saved != null && GatewayTokenStore.read(context) != null) {
            link = runCatching { wire.decodeFromString(MacLink.serializer(), saved) }.getOrNull()?.takeIf { MacLink.isHostname(it.hostname) }
        } else {
            // A link saved without a device token can't reach the gateway: pair again.
            prefs.edit().remove("mac.link").apply()
        }
        conversation.page = { before, limit ->
            if (startingNew) emptyList() else {
                val turns = runner.conversationTurns(current, before, limit)
                conversation.note(turns)
                turns.map { it.turn }
            }
        }
        conversation.lookUp = { runner.artifact(it) }
        restoreQueuedMessages(offlineQueueTarget)
    }

    // MARK: Where the calls go

    val route: RemoteRoute? get() = RemoteRoute.choose(lan, link, GatewayTokenStore.read(context) != null)
    val base: String get() = if (Sample.offline) Runner.NOWHERE else route?.url ?: runnerURL ?: Runner.NOWHERE
    private val offlineQueueTarget: String get() = link?.let { "mac:${it.hostname.lowercase()}" } ?: "runner:${runnerURL ?: ""}"

    val runner: Runner get() {
        // Paired with a Mac, a 401 means the pairing ended: say which.
        val refused = link?.let { if (pairedUntil?.let { it <= Instant.now() } == true) ReachNotice.Expired else ReachNotice.Removed }
        return Runner(base, GatewayTokenStore.read(context), refused?.let { "${it.title}. ${it.detail}" })
    }

    val notice: ReachNotice? get() = ReachNotice.of(connection, online, refusal, link != null, lastSeen, pairedUntil)
    val needsPairing: Boolean get() = (link == null && runnerURL == null) || notice == ReachNotice.Removed || notice == ReachNotice.Expired

    fun setRunner(url: String?) {
        prefs.edit().putString("runner.url", url).apply()
        runnerURL = url
        stop()
        forgetRunner()
        restoreQueuedMessages(offlineQueueTarget)
        start()
    }

    private fun linkTo(value: MacLink?) {
        val old = link
        link = value
        if (old?.hostname != value?.hostname) forgetRunner()
        if (value != null) prefs.edit().putString("mac.link", wire.encodeToString(MacLink.serializer(), value)).apply() else {
            prefs.edit().remove("mac.link").remove("gateway.expiresAt").apply()
            GatewayTokenStore.remove(context)
            pairedUntil = null
            // No alerts for an unpaired phone: Firebase forgets this token, and a new pairing gets a new one.
            if (Notifications.configured(context)) com.google.firebase.messaging.FirebaseMessaging.getInstance().deleteToken()
            pushToken = null
        }
        restoreQueuedMessages(offlineQueueTarget)
        if (started) finder.find(value?.name) { lan = it; reroute() }
        reroute()
    }

    fun unpair() = linkTo(null)

    private fun forgetRunner() {
        conversation.forget()
        conversations = null; current = null; startingNew = false; previews = emptyMap()
        gitHubChanges += 1; gitHubWork = null; gitHubLater = emptySet()
        echoes = emptyList(); failures = emptyMap(); requests.clear(); pending = null
    }

    /** Pairs with a Mac's gateway (#284): the QR secret or the six digits buy this phone's device token. */
    suspend fun pairGateway(url: String, credential: String, link: MacLink? = null) {
        val answer = Runner.redeem(url, credential, deviceName())
        val linked = link ?: answer.link ?: throw RunnerError("The Mac didn't say how to reach it away from home. Pair with its QR code instead.")
        GatewayTokenStore.save(context, answer.token)
        pairedUntil = answer.expiresAt
        answer.expiresAt?.let { prefs.edit().putLong("gateway.expiresAt", it.toEpochMilli()).apply() }
        refusal = null
        linkTo(linked)
    }

    private fun deviceName(): String =
        Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME)?.takeIf { it.isNotBlank() } ?: "${Build.MANUFACTURER} ${Build.MODEL}"

    // MARK: Work

    val work: List<WorkItem> get() = PhoneWork.items(visibleJobs, answering, since, seen)
    val loose: List<InboxItem> get() = PhoneWork.loose(answering, work)
    val answering: List<InboxItem> get() = InboxItem.waiting(inbox).filter { !waitsToSend(answer = it.id) }
    fun waitsToSend(answer: String) = offlineQueue.answers.any { it.id == answer }
    fun waitsToSendEcho(id: String) = offlineQueue.messages.any { it.id == id }
    val archived: List<Job> get() = PhoneWork.archived(jobs, clearedAt, archivedHere)
    val visibleJobs: List<Job> get() = jobs.filter { it.listed(clearedAt) && (it.isActive || it.id !in archivedHere) }
    val active: List<Job> get() = jobs.filter { it.isActive }
    fun decision(job: Job): InboxItem? = InboxItem.waiting(inbox).firstOrNull { it.job == job.id }
    fun accountName(id: String) = accounts.firstOrNull { it.id == id }?.name ?: id

    fun archive(id: String) {
        archivedHere = archivedHere + id
        prefs.edit().putStringSet("phone.archived", archivedHere).apply()
    }

    fun setSpeaks(on: Boolean) {
        speakReplies = on
        prefs.edit().putBoolean("voice.speakReplies", on).apply()
        if (!on) speaker.stop()
    }

    val talkHere: Talk get() = if (talkIn == current) talk else Talk.None

    val thread: List<Turn> get() {
        val here = echoes.filter { requests[it.id]?.conversation == current }
        return conversation.thread(ChatThread.pending(here, conversation.runnerTurns))
    }

    fun show(id: String?) {
        if (id == current && !startingNew) return
        current = id
        startingNew = false
        conversation.forget()
        scope.launch { conversation.reload() }
    }

    /** Where a job's page goes for its conversation: obid's (Some(id)), the one thread (Some(null)), or null. */
    fun conversationOf(job: Job): Optional? {
        if (conversations != null) return job.conversation?.let { Optional(it) }
        return if (ConversationModel.started(job.id, conversation.runnerTurns)) Optional(null) else null
    }
    data class Optional(val id: String?)

    // MARK: Voice

    fun dictate(update: (String) -> Unit) {
        if (voice.active || voice.finishing) return
        spoken = false
        speaker.stop()
        voice.start(update)
    }

    fun cancelVoice() {
        spoken = false
        voice.cancel()
        speaker.stop()
    }

    /** The app left the front: listening stops and keeps its words. */
    fun leftForeground() {
        voice.finish()
        spoken = false
        speaker.stop()
    }

    // MARK: Staying live

    fun start() {
        started = true
        finder.find(link?.name) { lan = it; reroute() }
        if (networkCallback == null) {
            val manager = context.getSystemService(ConnectivityManager::class.java)
            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                    scope.launch { online = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) }
                }
                override fun onLost(network: Network) { scope.launch { online = manager.activeNetwork != null } }
            }
            online = manager.activeNetwork != null
            manager.registerDefaultNetworkCallback(callback)
            networkCallback = callback
        }
        follow()
    }

    fun stop() {
        started = false
        finder.stop()
        networkCallback?.let { context.getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it) }
        networkCallback = null
        unfollow()
    }

    private fun reroute() {
        if (!started) return
        unfollow()
        follow()
    }

    private fun follow() {
        if (loop != null || Sample.offline) return
        if (route == null && runnerURL == null) return
        loop = scope.launch {
            var wait = 1000L
            while (isActive) {
                try {
                    runner.events().collect { event ->
                        if (event == RunnerEvent.Connected) { connected(); wait = 1000 } else apply(event)
                    }
                } catch (e: CancellationException) {
                    throw e
                } catch (e: Exception) {
                    val status = (e as? RunnerError)?.status
                    refusal = if (status == null && refusal == 401) 401 else status
                    connection = Connection.Offline(e.message ?: "Can't reach your Mac.")
                }
                delay(wait)
                wait = minOf(wait * 2, 15_000)
            }
        }
    }

    private fun unfollow() {
        loop?.cancel()
        loop = null
        if (connection == Connection.Live) connection = Connection.Connecting
    }

    private suspend fun connected() {
        val status = runner.status()
        host = status.runner.host
        accounts = status.accounts
        models = status.models
        clearedAt = status.clearedAt
        defaultMode = RunnerMode.of(status.permissions?.mode)
        take(runner.jobs())
        inbox = runner.inbox()
        readGitHub { runner.gitHubWork() }
        readRoutines()
        try { conversations = runner.conversations() } catch (e: Exception) { Log.e(TAG, "listing conversations failed: ${e.message}") }
        conversation.reload()
        loaded = true
        Notifications.clear(context, jobs.filter { !it.needsYou && !it.waitsForAnswer }.map { it.id }.toSet())
        connection = Connection.Live
        refusal = null
        lastSeen = Instant.now().also { prefs.edit().putLong("runner.lastSeen", it.toEpochMilli()).apply() }
        liveSession?.let { scope.launch { it.catchUp() } }
        // Jobs dispatched from the Mac notify too, so ask on connecting.
        askNotifications()
        flushQueued()
        flushQueuedInbox()
        registerPush()
        try { registerDevice(again = true) } catch (e: Exception) { Log.e(TAG, "registering this phone failed: ${e.message}") }
    }

    /** Hands the runner this phone's FCM token (obid's `POST /v1/notifications` with `platform: fcm`). */
    fun registerPush() {
        val token = pushToken ?: return
        if (connection != Connection.Live) return
        scope.launch {
            pushes = try { runner.registerNotifications(token) } catch (e: Exception) { Log.e(TAG, "handing the runner the push token failed: ${e.message}"); null }
        }
    }

    suspend fun readRoutines() {
        try { routines = runner.routines().orEmpty() } catch (e: Exception) { Log.e(TAG, "listing routines failed: ${e.message}") }
    }

    suspend fun reload() {
        try {
            take(runner.jobs())
            inbox = runner.inbox()
            readGitHub { runner.gitHubWork() }
            loaded = true
        } catch (e: Exception) {
            Log.e(TAG, "reloading jobs failed: ${e.message}")
        }
    }

    private suspend fun readGitHub(ask: suspend () -> GitHubWork?) {
        val asked = gitHubChanges
        val answer = try { ask() } catch (e: RunnerError) { if (e.status == 404) null else return } catch (e: Exception) { return }
        if (gitHubChanges == asked) gitHubWork = GitHubWork.applied(answer, gitHubWork)
    }

    suspend fun refreshGitHubWork() { if (!Sample.on) readGitHub { runner.refreshGitHubWork() } }

    suspend fun startGitHubWork(id: String) {
        val asked = gitHubChanges
        val job = runner.startGitHubWork(id)
        if (gitHubChanges == asked) apply(RunnerEvent.JobChanged(job))
    }

    fun sample(event: RunnerEvent) = apply(event)

    fun sampleData(jobs: List<Job>, conversations: List<RunnerConversation>, accounts: List<Account>) {
        putJobs(jobs); this.conversations = conversations; this.accounts = accounts; loaded = true
    }

    fun sampleUnreachable() { connection = Connection.Offline(""); lastSeen = Instant.now().minusSeconds(2400) }

    private fun putJobs(fresh: List<Job>) {
        val old = jobs
        jobs = fresh
        // Published, dismissed or running again, here or on the Mac: its alert goes.
        val needed = old.filter { it.needsYou || it.waitsForAnswer }.map { it.id }.toSet()
        val done = fresh.filter { !it.needsYou && !it.waitsForAnswer && it.id in needed }.map { it.id }.toSet()
        if (done.isNotEmpty()) Notifications.clear(context, done)
        JobsActivity.sync(context, fresh)
    }

    private fun apply(event: RunnerEvent) {
        when (event) {
            is RunnerEvent.JobChanged -> putJobs(jobs.indexOfFirst { it.id == event.job.id }.let { at ->
                if (at >= 0) jobs.toMutableList().also { it[at] = event.job } else listOf(event.job) + jobs
            })
            is RunnerEvent.Accounts -> accounts = event.accounts
            is RunnerEvent.Cleared -> clearedAt = event.at
            RunnerEvent.Connected -> liveSession?.let { scope.launch { it.catchUp() } }
            is RunnerEvent.Inbox -> inbox = inbox.filter { it.id != event.item.id } + listOfNotNull(event.item.takeIf { it.isOpen })
            is RunnerEvent.TurnAdded -> {
                event.turn.conversation?.let { previews = previews + (it to event.turn.text) }
                if (event.turn.conversation == null || (event.turn.conversation == current && !startingNew)) conversation.apply(event.turn, event.extras)
                settleEchoes()
            }
            is RunnerEvent.Step -> if (ConversationOrder.shows(event.step.conversation, current, startingNew)) conversation.apply(event.step)
            is RunnerEvent.Delta -> when {
                ConversationOrder.shows(event.delta.conversation, current, startingNew) -> conversation.apply(event.delta)
                startingNew && event.delta.conversation != null -> heldDeltas += event.delta
            }
            is RunnerEvent.Artifact -> conversation.apply(event.event)
            is RunnerEvent.GitHub -> gitHubWork = event.work
            is RunnerEvent.ConversationChanged -> take(event.conversation)
            RunnerEvent.Routine -> { routineChanges += 1; scope.launch { readRoutines() } }
            is RunnerEvent.Transcript -> liveSession?.apply(event.event)
        }
    }

    private fun settleEchoes() {
        echoes = ChatThread.pending(echoes, conversation.runnerTurns)
        val kept = echoes.map { it.id }.toSet()
        failures = failures.filterKeys { it in kept }
        requests.keys.retainAll(kept)
    }

    private fun drop(echo: String) {
        echoes = echoes.filter { it.id != echo }
        failures = failures - echo
        requests.remove(echo)
        if (pending == echo) pending = null
    }

    // MARK: Conversations

    suspend fun preview(id: String) {
        if (id in previews) return
        val last = runCatching { runner.conversationTurns(id, null, 1).lastOrNull() }.getOrNull() ?: return
        previews = previews + (id to last.text)
    }

    suspend fun update(id: String, title: String? = null, pinned: Boolean? = null) = take(runner.updateConversation(id, title, pinned))

    suspend fun delete(id: String) {
        runner.deleteConversation(id)
        take(RunnerConversation(id, deleted = true))
    }

    private fun take(changed: RunnerConversation) {
        val p = pending
        val request = p?.let { requests[it] }
        if (startingNew && p != null && request?.new == true && conversations.orEmpty().none { it.id == changed.id } &&
            ConversationOrder.started(request.said, changed)) adopt(changed.id, p)
        conversations?.let { conversations = ConversationOrder.placed(changed, it) }
        if (changed.deleted && changed.id == current) show(null)
        if (changed.deleted) drafts.keep("", Drafts.conversation(changed.id))
    }

    // MARK: Planning

    fun ask(words: String, spoken: Boolean = false, new: Boolean = false) {
        val said = ChatThread.words(words) ?: return
        cancelVoice()
        this.spoken = spoken
        val starts = new && conversations != null
        if (starts) {
            current = null
            startingNew = true
            heldDeltas.clear()
            conversation.forget()
        }
        plan(said, null, spoken, starts)
    }

    fun answer(option: String, said: String, question: Question) = plan(said, question.text to option)

    suspend fun stopTurn() {
        try {
            runner.stopConversation(talkIn ?: current)
            stopProblem = null
            conversation.settleSteps()
        } catch (e: RunnerError) {
            stopProblem = if (e.status == 404) "This runner can't stop a turn yet." else e.message
        } catch (e: Exception) { stopProblem = e.message }
    }

    fun cancel() {
        planning?.cancel()
        planning = null
        spoken = false
        speaker.stop()
        pending?.let(::drop)
        pending = null
        talk = Talk.None
    }

    fun retry(echo: String) {
        val request = requests[echo] ?: return
        offlineQueue.removeMessage(echo)
        drop(echo)
        plan(request.said, request.answer, request.voice, request.new, echo)
    }

    fun discard(echo: String) {
        offlineQueue.removeMessage(echo)
        drop(echo)
    }

    private fun plan(said: String, answer: Pair<String, String>?, voice: Boolean = false, new: Boolean = false,
                     id: String = java.util.UUID.randomUUID().toString().lowercase()) {
        planning?.cancel()
        speaker.stop()
        pending?.let(::drop)
        pending = null
        stopProblem = null
        talk = Talk.Thinking(said)
        val echo = Turn(id = id, who = Who.user, text = answer?.second ?: said, voice = if (voice) true else null)
        echoes = echoes + echo
        val request = Request(said, answer, voice, current, new)
        requests[echo.id] = request
        talkIn = current
        pending = echo.id
        if (connection != Connection.Live) {
            offlineQueue.queue(OfflineMessage(echo.id, said, answer?.first, answer?.second, voice, offlineQueueTarget, conversation = request.conversation,
                                              new = if (request.new) true else null))
            talk = Talk.Queued(said)
            pending = null
            return
        }
        planning = scope.launch {
            try {
                val planned = runner.planned(request.said, request.answer, request.conversation, request.new, echo.id)
                applyPlanned(planned, request, echo)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // The words stay in the thread with why, to try again or edit.
                failures = failures + (echo.id to (e.message ?: "It didn't go through."))
                finish(Talk.Reply(e.message ?: ""), emptyList(), request, echo)
            }
        }
    }

    private fun restoreQueuedMessages(target: String) {
        for (item in offlineQueue.messages.filter { it.target == target }) {
            requests[item.id] = Request(item.said, item.question?.let { q -> item.option?.let { q to it } }, item.voice, item.conversation, item.new ?: false)
            if (echoes.none { it.id == item.id }) echoes = echoes + Turn(id = item.id, who = Who.user, text = item.option ?: item.said, voice = if (item.voice) true else null)
        }
    }

    private suspend fun flushQueued() {
        val target = offlineQueueTarget
        val destination = runner
        offlineQueue.flushMessages(target) { item ->
            val request = requests[item.id] ?: Request(item.said, item.question?.let { q -> item.option?.let { q to it } }, item.voice, item.conversation, item.new ?: false)
            val echo = echoes.firstOrNull { it.id == item.id } ?: Turn(id = item.id, who = Who.user, text = item.option ?: item.said)
            val planned = destination.planned(request.said, request.answer, request.conversation, request.new, item.id)
            applyPlanned(planned, request, echo)
        }
    }

    private suspend fun flushQueuedInbox() {
        val destination = runner
        offlineQueue.flushAnswers(offlineQueueTarget) { item ->
            apply(RunnerEvent.Inbox(destination.settle(item.id, item.answer, item.done, item.laterInstant)))
        }
    }

    private fun applyPlanned(planned: PlannedTurn, request: Request, echo: Turn) {
        if (request.new) planned.conversation?.let { adopt(it, echo.id) }
        when (val result = planned.result) {
            is PlanResult.Asked -> finish(Talk.Asked(result.said, result.question), emptyList(), request, echo)
            is PlanResult.Reply -> finish(Talk.Reply(result.text), result.started, request, echo)
            PlanResult.Nothing -> finish(Talk.None, emptyList(), request, echo)
        }
    }

    private fun adopt(id: String, echo: String) {
        requests[echo]?.let { it.conversation = id; it.new = false }
        if (talkIn == null) talkIn = id
        if (!startingNew) return
        startingNew = false
        current = id
        heldDeltas.filter { it.conversation == id }.forEach(conversation::apply)
        heldDeltas.clear()
        scope.launch { conversation.reload(arriving = true) }
    }

    private fun finish(talk: Talk, started: List<Job>, request: Request, echo: Turn) {
        if (pending == echo.id) pending = null
        if (echo.id !in failures) drop(echo.id)
        conversation.settleLatestSteps()
        this.talk = talk
        started.forEach { apply(RunnerEvent.JobChanged(it)) }
        if (started.isNotEmpty()) askNotifications()
        if (request.voice && speakReplies) when (talk) {
            is Talk.Reply -> speaker.say(talk.text)
            is Talk.Asked -> speaker.say(talk.question.text)
            else -> {}
        }
    }

    // MARK: Jobs

    /** A notification was tapped: open its job on Home, and publish it if that's what was tapped. */
    fun open(id: String, publish: Boolean) {
        panel = null
        homePath = listOf(Route.Task(id))
        publishing = if (publish) id else null
    }

    fun push(route: Route) { homePath = homePath + route }
    fun pop() { homePath = homePath.dropLast(1) }

    suspend fun stop(id: String) = apply(RunnerEvent.JobChanged(runner.stop(id)))
    suspend fun stopAll() = runner.stopAll().jobs.forEach { apply(RunnerEvent.JobChanged(it)) }
    suspend fun dismiss(id: String) = apply(RunnerEvent.JobChanged(runner.dismiss(id)))
    suspend fun startNow(id: String) = apply(RunnerEvent.JobChanged(runner.startNow(id)))
    suspend fun move(id: String, agent: String?, account: String?, model: String?) = apply(RunnerEvent.JobChanged(runner.move(id, agent, account, model)))
    suspend fun clear() { clearedAt = runner.clear() }
    suspend fun tell(id: String, text: String) = apply(RunnerEvent.JobChanged(runner.tell(id, text)))
    suspend fun setMode(id: String, mode: RunnerMode) = apply(RunnerEvent.JobChanged(runner.setMode(id, mode)))
    suspend fun setDefaultMode(mode: RunnerMode) { runner.setDefaultMode(mode); defaultMode = mode }
    suspend fun setModels(models: ModelSettings) { this.models = runner.setModels(models) }
    suspend fun publishAction(id: String) = runner.publishAction(id)

    suspend fun answer(job: Job, decision: String, message: String? = null) {
        val permission = job.permissionValue ?: return
        apply(RunnerEvent.JobChanged(runner.answer(job.id, permission.id, decision, message)))
    }

    /** Settles an inbox item: an answer goes to its job, `done` lets it go, `later` puts it off. */
    suspend fun settle(id: String, answer: String? = null, done: Boolean? = null, later: Instant? = null) {
        if (connection != Connection.Live) {
            offlineQueue.queue(OfflineInboxAnswer(id, answer, done, later?.toEpochMilli(), offlineQueueTarget))
            return
        }
        apply(RunnerEvent.Inbox(runner.settle(id, answer, done, later)))
    }

    fun showing(id: String, shown: Boolean) { if (shown) onScreen.add(id) else onScreen.remove(id) }

    private suspend fun take(fresh: List<Job>) {
        val (kept, refetch) = JobList.keeping(fresh, jobs, onScreen)
        putJobs(if (Sample.on) Sample.jobs().filter { s -> kept.none { it.id == s.id } } + kept else kept)
        for (id in refetch) runCatching { runner.job(id) }.getOrNull()?.let { putJobs(JobList.placed(it, jobs)) }
    }

    suspend fun fetch(id: String) {
        if (jobs.any { it.id == id }) return
        try {
            val job = runner.job(id)
            if (jobs.none { it.id == id }) putJobs(JobList.placed(job, jobs))
        } catch (e: Exception) { Log.e(TAG, "fetching job $id failed: ${e.message}") }
    }

    /** The publishing key signs the action after a fresh biometric; the runner checks it, then pushes and opens a draft PR. */
    suspend fun publish(activity: FragmentActivity, id: String, action: String): String {
        if (!DeviceKey.isAvailable(context)) throw RunnerError("Publishing needs a fingerprint or face unlock set up on this phone.")
        val device = registerDevice()
        val approval = DeviceKey.approve(activity, id, action, device)
        val url = runner.publish(id, approval)
        jobs.firstOrNull { it.id == id }?.let { apply(RunnerEvent.JobChanged(it.copy(published = url, pushed = it.commits))) }
        return url
    }

    private val deviceKey get() = "device.${link?.hostname ?: runnerURL ?: ""}"
    val deviceID: String? get() = prefs.getString(deviceKey, null)

    /** Registers the phone's publishing key with the runner and returns its id; again on every connection. */
    suspend fun registerDevice(again: Boolean = false): String {
        if (!again) deviceID?.let { return it }
        if (!DeviceKey.isAvailable(context)) throw RunnerError("Publishing needs a fingerprint or face unlock set up on this phone.")
        val id = runner.register("Android", DeviceKey.publicKey())
        prefs.edit().putString(deviceKey, id).apply()
        return id
    }

    companion object { const val TAG = "Oby" }
}
