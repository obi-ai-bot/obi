package com.deskree.oby

import java.time.Duration
import java.time.Instant

/** One account's usage, as apps/shared/Usage.swift's Snapshot. */
data class UsageSnapshot(
    val agent: String, val name: String, val label: String?, val fiveHour: Double?, val sevenDay: Double?,
    val fiveHourResets: Instant?, val sevenDayResets: Instant?, val running: Int = 0, val reserveLiftedUntil: Instant? = null,
    val runnerSignedIn: Boolean? = null,
) {
    val tool get() = Usage.tool(agent)
    val signedIn get() = runnerSignedIn ?: (label != null)
    fun inReserve(now: Instant = Instant.now()) = (sevenDay ?: 0.0) >= Usage.RESERVE && (sevenDayResets?.let { it > now } ?: true)
    fun liftedUntil(now: Instant = Instant.now()) = reserveLiftedUntil?.takeIf { it > now }
    fun reserved(now: Instant = Instant.now()) = inReserve(now) && liftedUntil(now) == null
    fun mayLift(now: Instant = Instant.now()): Boolean {
        fun under(used: Double?, resets: Instant?) = (used ?: 0.0) < Usage.NEARLY_FULL || (resets?.let { it <= now } ?: false)
        return signedIn && reserved(now) && under(fiveHour, fiveHourResets) && under(sevenDay, sevenDayResets)
    }
}

object Usage {
    const val RESERVE = 0.8
    const val NEARLY_FULL = 0.95
    const val RESERVED_TEXT = "Reserved: only jobs you send it"
    const val LIFT_TEXT = "Use past reserve this week"

    fun tool(agent: String) = mapOf("claude" to "Claude Code", "codex" to "Codex", "cursor" to "Cursor", "gemini" to "Gemini")[agent]
        ?: agent.replaceFirstChar { it.uppercase() }

    fun percent(used: Double) = "${Math.round(used.coerceIn(0.0, 1.0) * 100)}%"

    fun agents(agents: List<String>): List<String> {
        val order = listOf("claude", "codex")
        return agents.distinct().sortedWith(compareBy({ order.indexOf(it).let { i -> if (i < 0) order.size else i } }, { tool(it) }))
    }

    fun reports(agent: String) = agent == "claude" || agent == "codex"

    fun notice(s: UsageSnapshot): String? = when {
        !s.signedIn -> "Signed out"
        !reports(s.agent) -> "${s.tool} doesn't report usage"
        s.fiveHour == null && s.sevenDay == null -> "No usage yet: it updates after its next job"
        else -> null
    }

    fun week(s: UsageSnapshot, now: Instant = Instant.now()): Double? {
        if (!s.signedIn) return null
        val used = s.sevenDay ?: return null
        return if (s.sevenDayResets?.let { it > now } != false) used else 0.0
    }

    fun useAnyway(s: UsageSnapshot) = "Use ${s.name} anyway" + (s.sevenDay?.let { " (${percent(it)} of week)" } ?: "")

    fun liftNote(s: UsageSnapshot): String {
        val until = s.sevenDayResets?.let { "until " + Format.weekdayShort(it) + " " + Format.time(it) } ?: "until its week resets"
        return "Oby keeps ${percent(1 - RESERVE)} of each week in reserve; this lifts it for ${s.name} $until."
    }

    fun liftable(reserved: List<String>?, among: List<Account>, now: Instant = Instant.now()) =
        reserved.orEmpty().mapNotNull { wanted -> among.firstOrNull { it.id == wanted } }.filter { it.usage.mayLift(now) }

    fun resetText(resets: Instant, now: Instant = Instant.now()): String {
        val seconds = Duration.between(now, resets).seconds
        if (seconds < 60) return "resets soon"
        if (seconds < 24 * 3600) {
            val parts = listOfNotNull((seconds / 3600).takeIf { it > 0 }?.let { "$it h" }, (seconds % 3600 / 60).takeIf { it > 0 }?.let { "$it min" })
            return "resets in " + parts.joinToString(" ")
        }
        return "resets " + Format.weekdayShort(resets) + " " + Format.time(resets)
    }

    fun resetsDay(date: Instant, now: Instant = Instant.now()): String {
        val seconds = Duration.between(now, date).seconds
        if (seconds < 24 * 3600) return "Resets in ${maxOf(1, Math.ceil(seconds / 3600.0).toInt())} h"
        return "Resets " + Format.weekday(date)
    }

    fun about(s: UsageSnapshot, now: Instant = Instant.now()): String {
        notice(s)?.let { return it }
        val resets = s.sevenDayResets
        return if (resets != null && resets > now && week(s, now) != null) resetsDay(resets, now) else ""
    }

    fun fiveHourLine(s: UsageSnapshot, now: Instant = Instant.now()): String? {
        val used = s.fiveHour ?: return null
        if (!s.signedIn || used <= 0.8 || s.fiveHourResets?.let { it <= now } == true) return null
        return "5-hour limit ${percent(used)} used" + (s.fiveHourResets?.let { " · " + resetText(it, now) } ?: "")
    }

    fun mostRoom(snapshots: List<UsageSnapshot>, now: Instant = Instant.now()): String {
        val weeks = snapshots.mapNotNull { s -> week(s, now)?.let { s to it } }
        val roomiest = weeks.minByOrNull { it.second } ?: return when {
            snapshots.isEmpty() -> "None yet"
            snapshots.any { it.signedIn } -> "No usage yet: it updates after the next job."
            else -> "No account is signed in."
        }
        return "Most room: ${roomiest.first.name} on ${roomiest.first.tool}, ${percent(1 - roomiest.second)} left this week"
    }
}
