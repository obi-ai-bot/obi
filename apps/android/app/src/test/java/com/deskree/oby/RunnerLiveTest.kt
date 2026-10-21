package com.deskree.oby

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assume.assumeTrue
import org.junit.Test

/**
 * The app's own pairing and runner client against a real Mac's gateway, end to end: skipped unless
 * `OBY_INVITE` holds an invitation (the QR code's text, from `POST /v1/pairing/invite`). It redeems
 * it as the phone does, then reads what Home, the jobs, the inbox and the conversations show, and
 * follows the event stream until the runner says it follows. It prints counts, never the token.
 */
class RunnerLiveTest {
    @Test fun pairsAndReadsWhatHomeShows() = runBlocking {
        val invite = System.getenv("OBY_INVITE")
        assumeTrue("set OBY_INVITE to run against a Mac", !invite.isNullOrBlank())
        val envelope = GatewayEnvelope.decode(invite!!)
        val answer = Runner.redeem(envelope.url, envelope.secret, "Android e2e")
        val link = answer.link ?: envelope.link
        val runner = Runner(link.tunnelURL, answer.token)
        val status = runner.status()
        val jobs = runner.jobs()
        val inbox = runner.inbox()
        val conversations = runner.conversations()
        val work = PhoneWork.items(jobs, InboxItem.waiting(inbox), java.time.Instant.now(), emptySet())
        println("paired with ${link.name} (${link.hostname}) until ${answer.expiresAt}")
        println("runner ${status.runner.host} ${status.runner.version}: ${status.accounts.size} accounts, ${jobs.size} jobs, ${inbox.size} inbox items, ${conversations?.size} conversations")
        println("Home says: ${HomeLine.attention(work.count { it.status == WorkStatus.Running }, WorkList.needsYou(work, PhoneWork.loose(InboxItem.waiting(inbox), work).size))}")
        println("chips: " + WorkList.kinds(work).joinToString { "${it.label} ${it.count}" })
        println("first jobs: " + jobs.take(3).joinToString { "${it.heading} [${it.badge.text}]" })
        println("events: " + withTimeout(30_000) { runner.events().first() })
    }
}
