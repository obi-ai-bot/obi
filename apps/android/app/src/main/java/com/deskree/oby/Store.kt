package com.deskree.oby

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.time.Instant

/** The app's private preferences (the iPhone's UserDefaults), never backed up (the manifest says so). */
object Store {
    fun prefs(context: Context): SharedPreferences = context.getSharedPreferences("oby", Context.MODE_PRIVATE)
}

/**
 * What was typed in a message box and not sent yet, by box (apps/shared/ChatThread.swift's Drafts):
 * restored when the box shows again, kept across a relaunch, and gone once sent, once its
 * conversation is deleted, or a week after it was last typed in.
 */
class Drafts(private val prefs: SharedPreferences) {
    @Serializable private data class Draft(val text: String, val at: Long)

    private val codec = MapSerializer(String.serializer(), Draft.serializer())

    private fun live(now: Long): Map<String, Draft> {
        val all = prefs.getString(KEY, null)?.let { runCatching { wire.decodeFromString(codec, it) }.getOrNull() }.orEmpty()
        return all.filterValues { now - it.at < KEPT }
    }

    fun text(box: String): String = live(System.currentTimeMillis())[box]?.text ?: ""

    fun keep(text: String, box: String) {
        val now = System.currentTimeMillis()
        val all = live(now).toMutableMap()
        if (ChatThread.words(text) == null) all.remove(box) else all[box] = Draft(text, now)
        prefs.edit().putString(KEY, wire.encodeToString(codec, all)).apply()
    }

    companion object {
        const val KEY = "ObyDrafts"
        const val KEPT = 7L * 86_400_000
        const val HOME = "home"
        fun conversation(id: String?) = "conversation:${id ?: "new"}"
        fun task(id: String) = "task:$id"
    }
}

@Serializable data class OfflineMessage(
    val id: String, val said: String, val question: String? = null, val option: String? = null, val voice: Boolean,
    val target: String? = null, val queuedAt: Long = System.currentTimeMillis(), val conversation: String? = null, val new: Boolean? = null,
)

@Serializable data class OfflineInboxAnswer(
    val id: String, val answer: String? = null, val done: Boolean? = null, val later: Long? = null, val target: String? = null,
    val queuedAt: Long = System.currentTimeMillis(),
) {
    val laterInstant: Instant? get() = later?.let(Instant::ofEpochMilli)
}

/**
 * What waits on this phone while the Mac can't be reached (apps/ios/app/Offline.swift): words and
 * answers, each for the runner it was meant for, sent in order once it's back. A message leaves the
 * queue only once the runner took it. At most 50 of each, for a week.
 */
class OfflineQueue(private val prefs: SharedPreferences) {
    // Compose state: what waits shows "Sends when your Mac is back" until it goes.
    var messages by mutableStateOf(read("phone.outbox", OfflineMessage.serializer())); private set
    var answers by mutableStateOf(read("phone.inboxOutbox", OfflineInboxAnswer.serializer())); private set

    init { prune(); persist() }

    private fun <T> read(key: String, s: kotlinx.serialization.KSerializer<T>): List<T> =
        prefs.getString(key, null)?.let { runCatching { wire.decodeFromString(ListSerializer(s), it) }.getOrNull() }.orEmpty()

    private fun persist() {
        prefs.edit()
            .putString("phone.outbox", wire.encodeToString(ListSerializer(OfflineMessage.serializer()), messages))
            .putString("phone.inboxOutbox", wire.encodeToString(ListSerializer(OfflineInboxAnswer.serializer()), answers))
            .apply()
    }

    private fun prune(now: Long = System.currentTimeMillis()) {
        val cutoff = now - MAX_AGE
        messages = messages.filter { it.queuedAt >= cutoff }.takeLast(MAX)
        answers = answers.filter { it.queuedAt >= cutoff }.takeLast(MAX)
    }

    private fun save() { prune(); persist() }

    fun queue(message: OfflineMessage) { messages = messages.filter { it.id != message.id } + message; save() }
    fun queue(answer: OfflineInboxAnswer) { answers = answers.filter { it.id != answer.id } + answer; save() }
    fun removeMessage(id: String) { messages = messages.filter { it.id != id }; save() }

    suspend fun flushMessages(target: String, send: suspend (OfflineMessage) -> Unit) {
        while (true) {
            val message = messages.firstOrNull { it.target == target } ?: return
            try { send(message) } catch (e: Exception) { save(); return }
            messages = messages - message
            save()
        }
    }

    suspend fun flushAnswers(target: String, send: suspend (OfflineInboxAnswer) -> Unit) {
        while (true) {
            val answer = answers.firstOrNull { it.target == target } ?: return
            try { send(answer) } catch (e: Exception) {
                // The runner no longer has it waiting (gone, or settled meanwhile): it leaves the queue, the next ones still go.
                if (!isAlreadySettled(e)) { save(); return }
            }
            answers = answers - answer
            save()
        }
    }

    companion object {
        const val MAX = 50
        const val MAX_AGE = 7L * 24 * 3600 * 1000
        fun isAlreadySettled(e: Exception) = (e as? RunnerError)?.status in listOf(404, 409)
    }
}
