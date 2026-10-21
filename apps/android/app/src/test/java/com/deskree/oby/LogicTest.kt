package com.deskree.oby

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

/** The rules the iPhone's tests hold (apps/ios/tests), on the Android port. */
class LogicTest {
    private fun job(json: String) = wire.decodeFromString(Job.serializer(), json)

    @Test fun anInvitationMustPointAtTheMacItNames() {
        val good = """{"url":"https://mac.tail8de49b.ts.net:8443","link":{"name":"Wellington's MacBook Pro","hostname":"mac.tail8de49b.ts.net:8443"},"secret":"s3"}"""
        assertEquals("s3", GatewayEnvelope.decode(good).secret)
        val elsewhere = """{"url":"https://evil.example.com","link":{"name":"Mac","hostname":"mac.tail8de49b.ts.net:8443"},"secret":"s3"}"""
        assertEquals("That invitation doesn't point at the Mac it names, so Oby won't pair with it.", runCatching { GatewayEnvelope.decode(elsewhere) }.exceptionOrNull()?.message)
        val home = """{"url":"http://192.168.1.20:8810","link":{"name":"Mac","hostname":"oby-abcdefghijklmnop.tetrix.pro"},"secret":"s3"}"""
        assertNotNull(GatewayEnvelope.decode(home))
        val plainAway = """{"url":"http://8.8.8.8:8810","link":{"name":"Mac","hostname":"oby-abcdefghijklmnop.tetrix.pro"},"secret":"s3"}"""
        assertTrue(runCatching { GatewayEnvelope.decode(plainAway) }.isFailure)
        assertTrue(runCatching { GatewayEnvelope.decode("not json") }.isFailure)
    }

    @Test fun hostnamesAreTheControlPlanesOrTailscales() {
        assertTrue(MacLink.isHostname("oby-abcdefghijklmnop.tetrix.pro"))
        assertTrue(MacLink.isHostname("tetrix-lab.tail8de49b.ts.net:8443"))
        assertFalse(MacLink.isHostname("oby-short.tetrix.pro"))
        assertFalse(MacLink.isHostname("example.com"))
    }

    @Test fun theCodeIsSixDigits() {
        assertEquals("123456", PairingCode.normalized("123 456"))
        assertEquals("123456", PairingCode.normalized("123-456"))
        assertNull(PairingCode.normalized("12345"))
        assertNull(PairingCode.normalized("12a456"))
    }

    @Test fun eventsSplitOnBlankLinesAndKeepLineSeparatorsInJson() {
        val parser = EventParser()
        val lines = listOf("event: job", """data: {"id":"j1","created":"2026-10-09T21:43:30Z","status":"running","summary":"a b"}""", "")
        val event = lines.firstNotNullOfOrNull { parser.feed(it) } as RunnerEvent.JobChanged
        assertEquals("a b", event.job.summary)
        assertNull(parser.feed(": ping"))
        assertNull(parser.feed(""))
        assertEquals(RunnerEvent.Routine, listOf("event: routine", "data: {}", "").firstNotNullOfOrNull { parser.feed(it) })
    }

    @Test fun aFactThatCantBeReadNeverFailsTheJob() {
        val j = job("""{"id":"j1","created":"2026-10-09T21:43:30.123Z","status":"done","activity":"nonsense","usage":{"input":10,"output":5},"pipeline":{"stages":[{"id":"work","title":"Work","state":"newState"}],"number":1,"total":1}}""")
        assertNull(j.facts.activity)
        assertEquals(15, j.facts.usage?.tokens)
        assertEquals("upcoming", j.stages.single().stateName)
    }

    @Test fun whatNeedsYou() {
        val publish = job("""{"id":"p","created":"2026-10-09T21:43:30Z","status":"done","base":"dev","commits":2,"kind":"fix"}""")
        assertTrue(publish.canPublish)
        assertTrue(publish.needsYou)
        assertEquals(JobBadge("Ready to publish", Tone.Orange), publish.badge)
        val dismissed = job("""{"id":"p","created":"2026-10-09T21:43:30Z","status":"failed","dismissed":"2026-10-09T21:50:00Z"}""")
        assertFalse(dismissed.needsYou)
        assertEquals("Dismissed", dismissed.badge.text)
    }

    @Test fun homeHasEveryKindAndCountsNeedsOnce() {
        val since = Instant.parse("2026-10-09T00:00:00Z")
        val jobs = listOf(
            job("""{"id":"r","created":"2026-10-08T21:43:30Z","status":"running","kind":"review"}"""),
            job("""{"id":"f","created":"2026-10-08T21:43:30Z","status":"failed","kind":"fix","issue":3}"""),
        )
        val items = PhoneWork.items(jobs, emptyList(), since, emptySet())
        assertEquals(listOf("Review PR", "Issues", "Tasks", "Routines"), WorkList.kinds(items).map { it.label })
        assertEquals(2, WorkList.needsYou(items, loose = 1))
        assertEquals("1 running task · 2 need you", HomeLine.attention(1, 2))
    }

    @Test fun permissionsOfferAlwaysAllowOnlyWithARule() {
        val withRule = CardOption.permission(RunnerPermission("p", title = "Run swift test", rule = "Bash(swift test:*)"))
        assertEquals(listOf("Allow once", "Always allow", "Deny"), withRule.map { it.label })
        assertTrue(withRule.last().destructive)
        assertFalse(withRule.last().safeOnReturn)
        assertEquals(listOf("Allow once", "Deny"), CardOption.permission(RunnerPermission("p", title = "Run")).map { it.label })
    }

    @Test fun theRunnersTurnListsTheEchoById() {
        val echo = Turn(id = "e1", who = Who.user, text = "Hi", conversation = "c1")
        assertTrue(ChatThread.lists(Turn(id = "e1", who = Who.user, text = "Hi", conversation = "c1"), echo))
        assertFalse(ChatThread.lists(Turn(id = "e2", who = Who.user, text = "Hi", conversation = "c1"), echo))
    }

    @Test fun theOwnerComesFromTheMacsName() {
        assertEquals("Wellington", HomeLine.owner("Wellington's MacBook Pro"))
        assertNull(HomeLine.owner("MacBook Pro"))
        assertEquals("What do you want me to work on, Wellington?", HomeLine.placeholder("Wellington"))
    }

    @Test fun wordsComeInOneAtATime() {
        val (shown, _) = WordReveal.shown("one two three", elapsed = 0.075)
        assertEquals("one two ", shown)
    }

    @Test fun plainHttpOnlyToHomeAddresses() {
        listOf("192.168.1.20", "10.0.0.2", "172.20.1.1", "169.254.3.4", "mac.local", "fd12:3456::1", "[fd00::2]", "fe80::1%wlan0")
            .forEach { assertTrue(it, GatewayEnvelope.isLocal(it)) }
        listOf("8.8.8.8", "172.32.0.1", "2001:db8::1", "fec0::1", "fd00::g", "example.com", "1.2.3")
            .forEach { assertFalse(it, GatewayEnvelope.isLocal(it)) }
    }

    @Test fun anApprovalSignsWhatTheRunnerChecks() {
        assertEquals("oby-publish\nj1\nPush it\n2026-10-20T17:51:00Z", String(Approval.message("j1", "Push it", "2026-10-20T17:51:00Z")))
    }
}
