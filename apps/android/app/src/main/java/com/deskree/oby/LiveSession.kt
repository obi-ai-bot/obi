package com.deskree.oby

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * One job's session as its view shows it, live (#785, apps/shared/LiveSession.swift): every page of
 * it from obid, then each `transcript` event as it comes, and a slow check every 5 seconds while the
 * job runs for anything an event missed. An entry's detail is fetched only when its row opens, and
 * only once obid is known to serve detail.
 */
class LiveSession(
    val job: String,
    private val load: suspend (Int?) -> TranscriptPage,
    private val loadDetail: suspend (Int) -> TranscriptDetail,
) {
    var entries by mutableStateOf(listOf<TranscriptEntry>()); private set
    var arriving by mutableStateOf<Int?>(null); private set
    var trimmed by mutableStateOf(false); private set
    var loaded by mutableStateOf(false); private set
    var unavailable by mutableStateOf(false); private set
    var failure by mutableStateOf<String?>(null); private set
    var detailServed by mutableStateOf<Boolean?>(null); private set
    private val details = mutableMapOf<Int, TranscriptDetail>()
    private var lastAppend = 0
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val counts: Map<TranscriptEntry.Filter, Int> get() = TranscriptEntry.Filter.entries.associateWith { f -> entries.count(f::takes) }

    suspend fun follow(live: Boolean) {
        do {
            catchUp()
            if (!live || unavailable) return
            delay(5000)
        } while (true)
    }

    suspend fun catchUp() {
        if (unavailable) return
        try {
            val fresh = pages(entries.lastOrNull()?.n)
            kept(fresh)
            failure = null
        } catch (e: RunnerError) {
            if (e.status == 404) unavailable = true else if (entries.isEmpty()) failure = e.message
        } catch (e: Exception) {
            if (entries.isEmpty()) failure = e.message
        }
        loaded = true
        askDetailServed()
    }

    fun apply(event: TranscriptEvent) {
        if (event.job != job) return
        val entry = event.entryValue
        if (entry != null) { kept(listOf(entry)); return }
        val n = event.n ?: return
        val append = event.append ?: return
        val at = entries.indexOfFirst { it.n == n }
        if (at < 0) return
        entries = entries.toMutableList().also { it[at] = it[at].copy(text = (it[at].text ?: it[at].summary ?: "") + append) }
        arriving = n
        lastAppend += 1
        val mark = lastAppend
        scope.launch { delay(1500); if (lastAppend == mark) arriving = null }
    }

    suspend fun detail(n: Int): TranscriptDetail? {
        details[n]?.let { return it }
        if (detailServed != true) return null
        return runCatching { loadDetail(n) }.getOrNull()?.also { details[n] = it }
    }

    private suspend fun askDetailServed() {
        if (detailServed != null) return
        val call = entries.firstOrNull { it.kind == "tool" && !it.running } ?: return
        try {
            details[call.n] = loadDetail(call.n)
            detailServed = true
        } catch (e: RunnerError) {
            if (e.status == 404) detailServed = false
        } catch (_: Exception) {}
    }

    private suspend fun pages(after: Int?): List<TranscriptEntry> {
        val fresh = mutableListOf<TranscriptEntry>()
        var from = after
        while (true) {
            val page = load(from)
            fresh += page.entries
            val next = page.next ?: break
            if (next == from || page.entries.isEmpty()) break
            from = next
        }
        return fresh
    }

    private fun kept(new: List<TranscriptEntry>) {
        val all = entries.toMutableList()
        val at = all.withIndex().associate { it.value.n to it.index }.toMutableMap()
        for (incoming in new) {
            val index = at[incoming.n]
            if (index != null) {
                val mine = all[index].text
                // Words that came as `append` after this copy was read stay.
                all[index] = if (mine != null && mine.length > incoming.words.length && mine.startsWith(incoming.words)) incoming.copy(text = mine) else incoming
            } else { at[incoming.n] = all.size; all += incoming }
        }
        all.sortBy { it.n }
        if (all.size > MOST) { entries = all.takeLast(MOST); trimmed = true } else entries = all
    }

    companion object { const val MOST = 2000 }
}
