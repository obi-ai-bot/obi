package com.deskree.oby

import android.Manifest
import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/** What the side panel shows (Sangam's Sidebar.tsx). */
enum class PanelSection { Home, Conversations }

/** The app: one Phone for every screen, and the notification channels. */
class ObyApp : Application() {
    lateinit var phone: Phone; private set

    override fun onCreate() {
        super.onCreate()
        Notifications.channels(this)
        phone = Phone(this)
    }

    companion object {
        fun phone(context: Context) = (context.applicationContext as ObyApp).phone
    }
}

/**
 * Looks for Macs advertising a gateway (`_oby._tcp`) on this network (apps/ios/app/ConnectScreen.swift's
 * MacFinder and MacBrowser): their names for the six digits, and the linked one's address at home.
 */
class MacFinder(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private var listener: NsdManager.DiscoveryListener? = null
    private var current: String? = null
    var names by mutableStateOf(listOf<String>()); private set
    private val services = mutableMapOf<String, NsdServiceInfo>()

    /** Watches the network; with `name`, `found` gets that Mac's gateway URL when it's seen (null once it's gone). */
    fun find(name: String?, found: (String?) -> Unit = {}) {
        stop()
        val discovery = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) { report(null, found) }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                services[info.serviceName] = info
                names = services.keys.sorted()
                if (info.serviceName == name) resolve(info, found)
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                services.remove(info.serviceName)
                names = services.keys.sorted()
                if (info.serviceName == name) report(null, found)
            }
        }
        listener = discovery
        runCatching { nsd.discoverServices(TYPE, NsdManager.PROTOCOL_DNS_SD, discovery) }
    }

    @Suppress("DEPRECATION")
    private fun resolve(info: NsdServiceInfo, found: (String?) -> Unit) {
        nsd.resolveService(info, object : NsdManager.ResolveListener {
            override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) { report(null, found) }
            override fun onServiceResolved(serviceInfo: NsdServiceInfo) {
                // The Mac's IPv4 address when it has one: an IPv6 link-local one needs a zone a URL can't carry.
                val address = if (android.os.Build.VERSION.SDK_INT >= 34) serviceInfo.hostAddresses.minByOrNull { it !is java.net.Inet4Address } else serviceInfo.host
                val host = address?.hostAddress?.substringBefore('%') ?: return report(null, found)
                report(RemoteRoute.lanURL(host, serviceInfo.port), found)
            }
        })
    }

    private fun report(url: String?, found: (String?) -> Unit) {
        if (url == current) return
        current = url
        android.os.Handler(android.os.Looper.getMainLooper()).post { found(url) }
    }

    fun stop() {
        listener?.let { runCatching { nsd.stopServiceDiscovery(it) } }
        listener = null
        services.clear()
        names = emptyList()
    }

    companion object {
        const val TYPE = "_oby._tcp"

        /** The gateway URL of the Mac named `name` on this network, once: null when it isn't seen within 10 seconds. */
        suspend fun resolve(context: Context, name: String): String? {
            val finder = MacFinder(context)
            return try {
                withTimeoutOrNull(10_000) {
                    kotlinx.coroutines.suspendCancellableCoroutine { done ->
                        finder.find(name) { url -> if (url != null && done.isActive) done.resume(url) }
                    }
                }
            } finally { finder.stop() }
        }
    }
}

/**
 * The alerts the runner sends when a job needs you (docs/runner-api.md, `POST /v1/notifications`):
 * "Ready to publish" with Publish and Open, a failed or interrupted job with Open. Tapping one opens
 * the job; Publish brings Oby forward, where the fingerprint or face signs it as it does in the app.
 */
object Notifications {
    const val JOBS = "jobs"
    const val WORK = "work"
    const val EXTRA_JOB = "job"
    const val EXTRA_PUBLISH = "publish"
    private const val EXTRA_NONCE = "nonce"
    private const val ALERT = 1

    /** This install's secret, carried by Oby's own notification taps: MainActivity is exported, so another app's intent without it opens nothing. */
    private fun nonce(context: Context): String {
        val prefs = Store.prefs(context)
        prefs.getString("notifications.nonce", null)?.let { return it }
        val bytes = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        val made = android.util.Base64.encodeToString(bytes, android.util.Base64.NO_WRAP)
        prefs.edit().putString("notifications.nonce", made).apply()
        return made
    }

    /** Whether `intent` is a tap on one of Oby's own notifications. */
    fun ours(context: Context, intent: Intent): Boolean {
        val given = intent.getStringExtra(EXTRA_NONCE) ?: return false
        return java.security.MessageDigest.isEqual(given.toByteArray(), nonce(context).toByteArray())
    }

    fun channels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(JOBS, context.getString(R.string.channel_jobs), NotificationManager.IMPORTANCE_HIGH).apply {
            description = context.getString(R.string.channel_jobs_about)
        })
        manager.createNotificationChannel(NotificationChannel(WORK, context.getString(R.string.channel_work), NotificationManager.IMPORTANCE_LOW).apply {
            description = context.getString(R.string.channel_work_about)
            setShowBadge(false)
        })
    }

    fun allowed(context: Context) = ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED &&
        NotificationManagerCompat.from(context).areNotificationsEnabled()

    fun open(context: Context, job: String, publish: Boolean): PendingIntent {
        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(EXTRA_JOB, job)
            putExtra(EXTRA_PUBLISH, publish)
            putExtra(EXTRA_NONCE, nonce(context))
        }
        return PendingIntent.getActivity(context, (job + publish).hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /** One job's alert, replacing any earlier one for the same job (`apns-collapse-id` on the iPhone). */
    @android.annotation.SuppressLint("MissingPermission") // Notifications.allowed checks it first.
    fun show(context: Context, job: String, title: String, body: String, category: String) {
        if (!allowed(context)) return
        val builder = NotificationCompat.Builder(context, JOBS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(open(context, job, false))
        if (category == "ready") builder.addAction(0, context.getString(R.string.action_publish), open(context, job, true))
        builder.addAction(0, context.getString(R.string.action_open), open(context, job, false))
        runCatching { NotificationManagerCompat.from(context).notify(job, ALERT, builder.build()) }
    }

    /** Takes these jobs' alerts away: they need nothing any more. */
    fun clear(context: Context, ids: Set<String>) {
        val manager = NotificationManagerCompat.from(context)
        ids.forEach { manager.cancel(it, ALERT) }
    }

    /** Push, once the user allowed alerts: Firebase gives this phone's token, and the runner gets it. */
    fun register(context: Context) {
        if (!allowed(context) || FirebaseApp.getApps(context).isEmpty()) return
        val messaging = FirebaseMessaging.getInstance()
        messaging.isAutoInitEnabled = true
        messaging.token.addOnSuccessListener { token ->
            ObyApp.phone(context).pushToken = token
            ObyApp.phone(context).registerPush()
        }.addOnFailureListener { Log.e(Phone.TAG, "Firebase gave no push token: ${it.message}") }
    }

    /** Whether this build can push at all: the owner's Firebase project is in it (README.md, "Owner's steps"). */
    fun configured(context: Context) = FirebaseApp.getApps(context).isNotEmpty()
}

/** FCM's data messages from obid (docs/runner-api.md): an alert for a job, or `clear` once it needs nothing. */
class ObyMessaging : FirebaseMessagingService() {
    override fun onNewToken(token: String) {
        CoroutineScope(Dispatchers.Main).launch {
            ObyApp.phone(this@ObyMessaging).pushToken = token
            ObyApp.phone(this@ObyMessaging).registerPush()
        }
    }

    override fun onMessageReceived(message: RemoteMessage) {
        // Unpaired, the phone shows nothing: the Mac drops its token too, but a message may be on its way.
        val prefs = Store.prefs(this)
        if (!prefs.contains("mac.link") && !prefs.contains("runner.url")) return
        val data = message.data
        data["clear"]?.let { Notifications.clear(this, setOf(it)); return }
        val job = data["job"] ?: return
        Notifications.show(this, job, data["title"] ?: "Oby", data["body"] ?: "", data["category"] ?: "job")
    }
}

/**
 * The iPhone's Live Activity, as far as Android goes: while Oby is open and an agent works, one quiet
 * ongoing notification says which job and its step, with a clock; when the last job ends it says how,
 * and goes 15 minutes later. When Oby leaves the front it says to open Oby for the latest.
 */
object JobsActivity {
    private const val ID = 2
    private var last: String? = null

    @android.annotation.SuppressLint("MissingPermission") // Notifications.allowed checks it first.
    fun sync(context: Context, jobs: List<Job>) {
        if (!Notifications.allowed(context)) return
        val active = jobs.filter { it.isActive }
        val job = active.firstOrNull { it.isWorking } ?: active.firstOrNull()
        val manager = NotificationManagerCompat.from(context)
        val builder = NotificationCompat.Builder(context, Notifications.WORK).setSmallIcon(R.drawable.ic_notification).setSilent(true)
        if (job != null) {
            val working = active.count { it.isWorking }
            val text = listOf(job.stageNow, job.step.ifEmpty { "Working" }).filterNotNull().joinToString(" · ")
            val key = "${job.id}|$text|$working"
            if (key == last) return
            last = key
            builder.setContentTitle(job.heading).setContentText(text).setOngoing(true).setUsesChronometer(true)
                .setWhen((job.started ?: job.created).toEpochMilli()).setContentIntent(Notifications.open(context, job.id, false))
            if (working > 1) builder.setSubText("$working working")
        } else {
            if (last == null) return
            last = null
            val ended = jobs.filter { it.finished != null }.maxByOrNull { it.finished!! } ?: return manager.cancel(ID)
            builder.setContentTitle(ended.heading).setContentText(if (ended.st == JobStatus.failed) "Failed" else if (ended.st == JobStatus.done) "Done" else ended.badge.text)
                .setAutoCancel(true).setTimeoutAfter(15 * 60_000).setContentIntent(Notifications.open(context, ended.id, false))
        }
        runCatching { manager.notify(ID, builder.build()) }
    }

    /** Oby left the front: the step shown may be old now. */
    @android.annotation.SuppressLint("MissingPermission") // Notifications.allowed checks it first.
    fun markStale(context: Context, jobs: List<Job>) {
        if (last == null || !Notifications.allowed(context)) return
        val job = jobs.firstOrNull { it.isWorking } ?: jobs.firstOrNull { it.isActive } ?: return
        runCatching {
            NotificationManagerCompat.from(context).notify(ID, NotificationCompat.Builder(context, Notifications.WORK)
                .setSmallIcon(R.drawable.ic_notification).setSilent(true).setOngoing(false).setContentTitle(job.heading)
                .setContentText("Open Oby for the latest").setContentIntent(Notifications.open(context, job.id, false)).build())
        }
        last = null
    }
}

/**
 * Debug builds only (apps/ios/app/SampleTasks.swift): launched with `--ez ObySampleTasks true`, Home
 * shows three made-up tasks, so an emulator with no runner jobs can show Sangam's cards and pages.
 * `ObySampleOffline` reaches no runner, `ObySampleUnreachable` shows the Mac out of reach,
 * `ObySampleUnpaired` with offline shows Connect, `ObySampleRoute settings|task:<id>` opens a page,
 * `ObySampleTalk <seconds>` brings Oby's answer into the thread a word at a time. Nothing is sent.
 */
object Sample {
    var on = false
    var offline = false

    fun apply(phone: Phone, intent: Intent) {
        if (!BuildConfig.DEBUG) return
        // `--es ObyClipboard '<invitation>'`: on the clipboard, for Paste invitation on an emulator.
        intent.getStringExtra("ObyClipboard")?.let { text ->
            phone.context.getSystemService(android.content.ClipboardManager::class.java)
                .setPrimaryClip(android.content.ClipData.newPlainText("Oby invitation", text))
        }
        on = intent.getBooleanExtra("ObySampleTasks", false)
        offline = intent.getBooleanExtra("ObySampleOffline", false)
        if (offline && !intent.getBooleanExtra("ObySampleUnpaired", false) && phone.runnerURL == null && phone.link == null) phone.setRunner(Runner.NOWHERE)
        if (on) phone.sampleData(jobs(), conversations(), accounts())
        if (intent.getBooleanExtra("ObySampleUnreachable", false)) phone.sampleUnreachable()
        intent.getStringExtra("ObySampleRoute")?.let { route ->
            phone.homePath = when {
                route == "settings" -> listOf(Route.Settings)
                route.startsWith("task:") -> listOf(Route.Task(route.removePrefix("task:")))
                route.startsWith("kind:") -> WorkList.kinds(phone.work).firstOrNull { it.id == route.removePrefix("kind:") }?.type?.let { listOf(Route.Kind(it)) }.orEmpty()
                route == "all" -> listOf(Route.All)
                else -> emptyList()
            }
        }
        val talk = intent.getIntExtra("ObySampleTalk", 0)
        if (talk > 0) {
            phone.homePath = listOf(Route.Conversation(null))
            phone.conversation.apply(Turn(id = "sample-ask", who = Who.user, text = "Where's the login screen task at?"))
            CoroutineScope(Dispatchers.Main).launch {
                delay(talk * 1000L)
                phone.conversation.apply(Turn(id = "sample-answer", who = Who.oby, text = "Claude is on it in deskree-inc/oby: the empty state now says what to do next, and it's running `swift test` before the review. Two of five stages are done, and nothing needs you yet. I'll tell you when it opens the pull request, or sooner if it gets stuck on a check.", jobs = listOf("sample-run")))
            }
        }
    }

    private fun at(minutes: Int) = java.time.Instant.now().minusSeconds(minutes * 60L).toString()

    private fun stages(vararg states: String) = listOf("Plan", "Work", "Check", "Review", "Merge").zip(states).mapIndexed { i, (title, state) ->
        """{"id": "s$i", "title": "$title", "state": "$state"}"""
    }.joinToString(", ")

    fun jobs(): List<Job> = listOf(
        """{"id": "sample-run", "request": "Make the login screen's empty state say what to do next", "agent": "claude", "account": "personal", "repo": "deskree-inc/oby", "branch": "oby/fix-12", "base": "dev", "kind": "fix", "issue": 12, "title": "Login screen empty state", "task": "Fix #12", "status": "running", "step": "Running swift test", "summary": "", "created": "${at(12)}", "started": "${at(12)}", "rounds": 4, "round": 2, "check": "swift test", "mode": "acceptEdits", "pipeline": {"stages": [${stages("done", "current", "upcoming", "upcoming", "upcoming")}], "number": 2, "total": 5}}""",
        """{"id": "sample-needs", "request": "Review oby PR #33", "agent": "codex", "account": "deskree", "repo": "deskree-inc/oby", "branch": "oby/review-33", "base": "dev", "kind": "review", "pr": 33, "title": "Review oby #33", "task": "Review #33", "status": "running", "step": "Waiting for your OK", "summary": "", "created": "${at(40)}", "started": "${at(40)}", "mode": "ask", "permission": {"id": "p1", "tool": "Bash", "title": "Run swift test", "detail": "swift test --filter RunnerTests", "rule": "Bash(swift test:*)"}, "pipeline": {"stages": [${stages("done", "current", "upcoming", "upcoming", "skipped")}], "number": 2, "total": 5}}""",
        """{"id": "sample-done", "request": "Add the About row to Settings", "agent": "claude", "account": "personal", "repo": "deskree-inc/oby", "branch": "oby/about", "base": "dev", "kind": "build", "title": "Settings About row", "task": "Add About", "status": "done", "step": "", "summary": "Settings has an About section with the app's version and the runner it reaches.", "created": "${at(36)}", "started": "${at(36)}", "finished": "${at(2)}", "commits": 2, "pushed": 2, "published": "https://github.com/deskree-inc/oby/pull/412", "pipeline": {"stages": [${stages("done", "done", "done", "done", "done")}], "number": 5, "total": 5}, "tetrix": {"connected": true, "calls": {"search_entities": 2, "get_entity": 1, "save_session": 1}, "context": true, "saved": ["ses_8f2a"], "gaps": {"noResults": ["deskree-inc/oby#412"], "unknownFiles": ["apps/ios/app/SettingsScreen.swift"]}}}""",
    ).mapNotNull { runCatching { wire.decodeFromString(Job.serializer(), it) }.onFailure { e -> Log.e(Phone.TAG, "sample job: ${e.message}") }.getOrNull() }

    fun accounts(): List<Account> {
        val resets = java.time.Instant.now().plusSeconds(3 * 86_400).toString()
        return listOf(
            """{"id": "personal", "agent": "claude", "name": "Personal", "signedIn": true, "sevenDay": 0.84, "sevenDayResets": "$resets", "running": 1, "tetrix": true, "tetrixJobs": 12, "tetrixUsed": 9}""",
            """{"id": "deskree", "agent": "codex", "name": "Deskree", "signedIn": true, "sevenDay": 0.12, "sevenDayResets": "$resets", "running": 0, "tetrix": true, "tetrixJobs": 4, "tetrixUsed": 4}""",
        ).map { wire.decodeFromString(Account.serializer(), it) }
    }

    fun conversations() = listOf(
        RunnerConversation("sample-c1", "Why does the login screen look empty?", lastActivity = java.time.Instant.now().minusSeconds(120),
                           turn = RunnerConversation.Match(text = "On it. Claude is making the empty state say what to do next.")),
        RunnerConversation("sample-c2", "Where is 0.9 at?", lastActivity = java.time.Instant.now().minusSeconds(3600),
                           turn = RunnerConversation.Match(text = "It went out on Tuesday; the About row came after.")),
    )
}
