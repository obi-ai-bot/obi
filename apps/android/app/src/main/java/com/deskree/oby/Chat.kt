package com.deskree.oby

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.PictureAsPdf
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The side panel's Conversations (Sangam's Sidebar.tsx, #493): obid's conversations, Pinned then
 * Recent, each with its last line and how long ago; search finds them by what was said. Hold one for
 * Pin, Rename and Delete. A runner that keeps one thread lists just that one.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ConversationsColumn(open: (Route) -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var query by remember { mutableStateOf("") }
    var found by remember { mutableStateOf<List<RunnerConversation>?>(null) }
    var renaming by remember { mutableStateOf<RunnerConversation?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var held by remember { mutableStateOf<String?>(null) }
    val now = rememberNow(60)

    // obid's own search (`?q=`), a moment after the typing stops.
    LaunchedEffect(query) {
        val words = query.trim()
        if (words.isEmpty() || phone.conversations == null) { found = null; return@LaunchedEffect }
        delay(300)
        try { found = phone.runner.conversations(words).orEmpty(); problem = null } catch (e: Exception) { problem = e.message }
    }
    fun run(work: suspend () -> Unit) { scope.launch { problem = try { work(); null } catch (e: Exception) { e.message } } }

    Column(Modifier.fillMaxSize()) {
        Box(Modifier.padding(horizontal = 12.dp).padding(bottom = 8.dp)) { SearchField(query, "Search conversations") { query = it } }
        val list = found ?: phone.conversations
        if (list == null) {
            ConversationRow("Oby", phone.conversation.runnerTurns.lastOrNull()?.text, phone.conversation.runnerTurns.lastOrNull()?.date, now) { open(Route.Conversation(null)) }
            return@Column
        }
        val (pinned, recent) = ConversationOrder.sections(list)
        LazyColumn(Modifier.fillMaxSize()) {
            if (list.isEmpty()) item { T(if (found == null) "No conversations yet" else "Nothing matches “$query”", Tokens.textBase, c.muted, modifier = Modifier.padding(12.dp)) }
            for ((label, rows) in listOf("Pinned" to pinned, "Recent" to recent)) {
                if (rows.isEmpty()) continue
                // No headings while nothing's pinned, as the design has it.
                if (pinned.isNotEmpty()) item(label) { T(label, Tokens.textSm, c.label, modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)) }
                items(rows, key = { it.id }) { conversation ->
                    LaunchedEffect(conversation.id) { phone.preview(conversation.id) }
                    Box {
                        ConversationRow(conversation.title.ifEmpty { "Conversation" }, conversation.turn?.text ?: phone.previews[conversation.id], conversation.latest, now,
                                        onLong = { held = conversation.id }) { open(Route.Conversation(conversation.id)) }
                        DropdownMenu(held == conversation.id, { held = null }, containerColor = c.surface) {
                            DropdownMenuItem({ T(if (conversation.pinned) "Unpin" else "Pin", Tokens.textBase, c.ink) }, { held = null; run { phone.update(conversation.id, pinned = !conversation.pinned) } })
                            DropdownMenuItem({ T("Rename", Tokens.textBase, c.ink) }, { held = null; renaming = conversation })
                            DropdownMenuItem({ T("Delete", Tokens.textBase, c.danger) }, { held = null; run { phone.delete(conversation.id) } })
                        }
                    }
                }
            }
            problem?.let { item { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(12.dp)) } }
        }
    }
    renaming?.let { conversation -> RenameDialog(conversation.title, { renaming = null }) { name -> run { phone.update(conversation.id, title = name) } } }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun ConversationRow(title: String, last: String?, at: java.time.Instant?, now: java.time.Instant, onLong: (() -> Unit)? = null, onClick: () -> Unit) {
    Column(Modifier.fillMaxWidth().combinedClickable(onClick = onClick, onLongClick = onLong).padding(horizontal = 12.dp, vertical = 8.dp),
           verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            FadeText(title, Tokens.textBase, Tokens.item, modifier = Modifier.weight(1f))
            if (at != null && at > java.time.Instant.EPOCH) T(ConversationOrder.ago(at, now), Tokens.textSm, Tokens.muted, modifier = Modifier.padding(start = 8.dp))
        }
        if (!last.isNullOrEmpty()) FadeText(last, Tokens.textSm, Tokens.muted)
    }
}

@Composable
fun RenameDialog(title: String, dismiss: () -> Unit, save: (String) -> Unit) {
    var name by remember { mutableStateOf(title) }
    AlertDialog(onDismissRequest = dismiss, containerColor = Tokens.c.surface,
        title = { T("Rename conversation", 17.sp, Tokens.ink, FontWeight.SemiBold) },
        text = { SetField(name, "Name", 260.dp, { name = it }) },
        confirmButton = { TextButton({ name.trim().takeIf { it.isNotEmpty() }?.let(save); dismiss() }) { T("Save", Tokens.textBase, Tokens.ink) } },
        dismissButton = { TextButton(dismiss) { T("Cancel", Tokens.textBase, Tokens.muted) } })
}

/**
 * A conversation with Oby (Sangam's ChatView.tsx, apps/ios/app/Chat.swift): your words in bubbles at
 * the right, Oby's as plain text under its face, in runs with the time under each; the tasks an answer
 * started as cards under it, and their decisions; Oby at work; its question; and the box at the foot.
 */
@Composable
fun ConversationPage(id: String?, isNew: Boolean) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var adopted by remember { mutableStateOf<String?>(null) }
    val shown = if (isNew) adopted else id
    val conversation = shown?.let { s -> phone.conversations?.firstOrNull { it.id == s } }
    val talk = phone.talkHere
    val thinking = talk is Phone.Talk.Thinking
    val working = phone.conversation.working
    var menu by remember { mutableStateOf(false) }
    var renaming by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var fill by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(shown) { if (!isNew || adopted != null) phone.show(shown) }
    LaunchedEffect(phone.current, phone.startingNew) { if (isNew && adopted == null && !phone.startingNew) phone.current?.let { adopted = it } }
    fun run(work: suspend () -> Unit) { scope.launch { problem = try { work(); null } catch (e: Exception) { e.message } } }

    Page(conversation?.title ?: if (isNew) "New conversation" else "Oby", menu = if (conversation == null) null else {
        {
            MenuButton("Conversation options") { menu = true }
            DropdownMenu(menu, { menu = false }, containerColor = c.surface) {
                DropdownMenuItem({ T(if (conversation.pinned) "Unpin" else "Pin", Tokens.textBase, c.ink) }, { menu = false; run { phone.update(conversation.id, pinned = !conversation.pinned) } })
                DropdownMenuItem({ T("Rename", Tokens.textBase, c.ink) }, { menu = false; renaming = true })
            }
        }
    }) {
        Column(Modifier.fillMaxSize().imePadding()) {
            Thread(shown, Modifier.weight(1f), problem) { text -> fill = text }
            Composer(Drafts.conversation(shown), "Reply to Oby…", fill = fill, onFilled = { fill = null },
                     onStop = if (thinking || working) ({ scope.launch { phone.stopTurn() } }) else null,
                     onSend = { text, spoken ->
                         val asked = phone.talkHere
                         // While Oby asks its question, words in the box answer it; else they're a message for Oby.
                         if (asked is Phone.Talk.Asked) phone.answer(text, asked.said, asked.question) else phone.ask(text, spoken)
                     })
        }
    }
    if (renaming && conversation != null) RenameDialog(conversation.title, { renaming = false }) { name -> run { phone.update(conversation.id, title = name) } }
}

@Composable
private fun Thread(shown: String?, modifier: Modifier, problem: String?, edit: (String) -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    val now = rememberNow()
    val turns = phone.thread
    val rows = ChatRuns.rows(turns)
    val talk = phone.talkHere
    val thinking = talk is Phone.Talk.Thinking
    val working = phone.conversation.working
    val startedBy = { job: Job -> ThreadTaskLine.startedBy(job.turn, job.conversation, shown) }
    val placed = ThreadTaskLine.shown(turns, phone.jobs, startedBy, phone.conversation::endedTurn)
    val decisions = InboxItem.waiting(phone.inbox, now)
    val list = rememberLazyListState()
    val end = rows.size + 3
    LaunchedEffect(turns.lastOrNull()?.id, phone.talk, phone.conversation.steps, phone.conversation.streamed) { if (end > 0) list.animateScrollToItem(end) }

    BoxWithConstraints(modifier.fillMaxWidth()) {
        val column = maxWidth - Tokens.gutter * 2
        LazyColumn(Modifier.fillMaxSize().semantics { contentDescription = "Conversation with Oby" }, state = list,
                   contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Tokens.gutter, vertical = 12.dp)) {
            if (phone.conversation.hasOlder) item("older") {
                T(if (phone.conversation.loading) "Loading…" else "Earlier", Tokens.textMd, c.text, center = true,
                  modifier = Modifier.fillMaxWidth().padding(bottom = 16.dp).clickable(enabled = !phone.conversation.loading) { scope.launch { phone.conversation.loadOlder() } })
            }
            phone.conversation.problem?.let { item("problem") { T("The runner's thread couldn't be read: $it", Tokens.textSm, c.needsInk, modifier = Modifier.padding(bottom = 12.dp)) } }
            if (turns.isEmpty() && !thinking) item("empty") {
                T(if (phone.loaded) "Ask Oby anything." else "Reaching the runner…", Tokens.textBase, c.muted, center = true, modifier = Modifier.fillMaxWidth().padding(top = 40.dp))
            }
            items(rows.size, key = { rows[it].turn.id }) { index ->
                val row = rows[index]
                LaunchedEffect(row.turn.jobs) { ConversationModel.missing(row.turn, phone.jobs).forEach { phone.fetch(it) } }
                MessageRow(row, index == 0, now, column,
                    jobs = ThreadTaskLine.cards(row.turn, turns, phone.jobs, startedBy),
                    followUps = { job -> if (phone.conversation.endedTurn(row.turn)) emptyList() else ThreadTaskLine.attached(job, phone.jobs, placed) },
                    steps = phone.conversation.steps(row.turn, turns), streamed = phone.conversation.streamed(row.turn, turns),
                    failure = phone.failures[row.turn.id], waiting = phone.waitsToSendEcho(row.turn.id),
                    onRetry = { phone.retry(row.turn.id) }, onEdit = { edit(row.turn.text); phone.discard(row.turn.id) })
                for (item in decisions.filter { row.turn.jobs?.contains(it.job) == true }) Box(Modifier.padding(top = 12.dp)) { InboxDecision(item) }
            }
            if ((thinking || working) && phone.conversation.streamed.isEmpty()) item("work") {
                ObyAtWork(if (working) "Working" else "Thinking", phone.stopProblem, thinking) { phone.cancel() }
            }
            if (talk is Phone.Talk.Asked) item("ask") {
                Box(Modifier.padding(top = 16.dp).fillMaxWidth().background(c.chip, RoundedCornerShape(Tokens.askRadius)).padding(16.dp)) {
                    AskCard(AskKind.label("question", talk.question.plan != null), talk.question.text, talk.question.cardOptions,
                            onChoose = { phone.answer(it.answer, talk.said, talk.question) }, plan = talk.question.plan,
                            hint = "Or answer in your own words below", onLater = { phone.cancel() })
                }
            }
            problem?.let { item("p") { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 8.dp)) } }
            item("end") { Spacer(Modifier.height(1.dp)) }
        }
    }
}

/** One message in its run: yours in a bubble at the right, Oby's as plain text under its face, then what Oby did and the tasks it started. */
@Composable
private fun MessageRow(row: ChatRuns.Row, first: Boolean, now: java.time.Instant, column: androidx.compose.ui.unit.Dp, jobs: List<Job>,
                       followUps: (Job) -> List<Job>, steps: List<TurnStep>, streamed: ConversationModel.Streamed?, failure: String?, waiting: Boolean,
                       onRetry: () -> Unit, onEdit: () -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val turn = row.turn
    val yours = turn.who == Who.user
    Column(Modifier.fillMaxWidth().padding(top = if (first) 0.dp else if (row.continues) 4.dp else 24.dp),
           horizontalAlignment = if (yours) Alignment.End else Alignment.Start, verticalArrangement = Arrangement.spacedBy(10.dp)) {
        if (!yours && !row.continues) ObyMark()
        if (yours) {
            Bubble(column) { SaidText(turn.text, c.ink, plain = true) }
            if (waiting) T(ReachNotice.WAITING, Tokens.textSm, c.muted)
            if (failure != null) {
                T("Didn't reach Oby: $failure", Tokens.textSm, c.danger)
                Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    T("Try again", Tokens.textSm, c.ink, FontWeight.Medium, Modifier.clickable(onClick = onRetry).padding(vertical = 6.dp))
                    T("Edit", Tokens.textSm, c.ink, FontWeight.Medium, Modifier.clickable(onClick = onEdit).padding(vertical = 6.dp))
                }
            }
        } else {
            if (turn.text.isNotEmpty()) ArrivingSaid(turn.text, phone.conversation.arrived[turn.id], c.item)
            turn.details?.let { SaidText(it, c.text) }
        }
        if (steps.isNotEmpty()) ToolSteps(steps, streamed != null)
        if (streamed != null) StreamingAnswer(streamed)
        for (ref in phone.conversation.artifactRefs(turn)) ArtifactShelf(ref)
        for (job in jobs) {
            ThreadTask(job, phone.accountName(job.account))
            for (ref in job.artifactRefs) ArtifactShelf(ref)
            for (next in followUps(job)) {
                T(ThreadTaskLine.followUp(next, phone.accountName(next.account)), Tokens.textMd, c.muted)
                ThreadTask(next, phone.accountName(next.account))
            }
        }
        if (row.endsRun) T(ChatRuns.clock(turn.date, now), 11.sp, c.muted)
    }
}

/** A task an answer started, as a small card under it (Sangam's ThreadTask): a tap opens its page. */
@Composable
fun ThreadTask(job: Job, account: String) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val mark = ThreadTaskLine.mark(job)
    Row(Modifier.fillMaxWidth().background(c.cardFill, RoundedCornerShape(14.dp)).border(1.dp, c.line, RoundedCornerShape(14.dp))
        .clickable { phone.push(Route.Task(job.id)) }.padding(horizontal = 12.dp, vertical = 10.dp)
        .semantics { contentDescription = "Open ${job.heading}, ${ThreadTaskLine.status(mark)}" }, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.width(16.dp).padding(top = 2.dp)) { AgentMark(job.agent, 14.dp) }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            T(job.heading, Tokens.textMd, c.ink, FontWeight.Medium, lines = 1)
            T(ThreadTaskLine.meta(job, mark, account), Tokens.textSm, c.muted, lines = 1)
            Box(Modifier.padding(top = 4.dp)) { JobCardLines(job) }
        }
        Box(Modifier.padding(top = 3.dp)) { WorkMarkView(mark) }
        Icon(Icons.Filled.ChevronRight, null, Modifier.size(16.dp).padding(top = 2.dp), tint = c.muted.copy(alpha = 0.6f))
    }
}

/** Under a job card's meta line: while it runs, its stage and latest step with the sheen, and the stage bar; once it ended, its result. */
@Composable
fun JobCardLines(job: Job) {
    val c = Tokens.c
    val open = rememberOpener()
    val outcome = job.outcome
    if (outcome != null) {
        if (outcome.link != null) T(outcome.text, Tokens.textSm, c.text, FontWeight.Medium, Modifier.clickable { open(outcome.link) })
        else FadeText(outcome.text, Tokens.textSm, if (outcome.failed) c.danger else c.text)
    } else job.liveLine?.let { line ->
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Sheen(line, Tokens.textSm)
            StageBar(job, needs = false)
        }
    }
}

/** Oby at work, last in the thread: its face, what it's on with a sheen, and while this phone waits for the answer, a way to stop waiting. */
@Composable
private fun ObyAtWork(line: String, problem: String?, waiting: Boolean, onCancel: () -> Unit) {
    Column(Modifier.padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ObyFaceLive(live = true)
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Sheen(line)
            if (waiting) T("Cancel", Tokens.textSm, Tokens.muted, modifier = Modifier.clickable(onClick = onCancel).padding(6.dp))
        }
        problem?.let { T(it, Tokens.textSm, Tokens.needsInk) }
    }
}

/** Oby's words while they're still being written: its face and the words coming in, word by word. */
@Composable
private fun StreamingAnswer(streamed: ConversationModel.Streamed) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        ObyFaceLive(live = false)
        ArrivingSaid(streamed.text, streamed.since, Tokens.item)
    }
}

/** What Oby did for your words: while it works, the last four lines; once its words start, or nothing runs, one muted line that a tap opens. */
@Composable
private fun ToolSteps(steps: List<TurnStep>, words: Boolean) {
    val c = Tokens.c
    val folded = ToolLine.folded(steps, words)
    var open by remember { mutableStateOf(false) }
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (folded) Row(Modifier.clickable { open = !open }, verticalAlignment = Alignment.CenterVertically) {
            FadeText(ToolLine.summary(steps), Tokens.textMd, c.muted, modifier = Modifier.weight(1f, fill = false))
            Icon(Icons.Filled.ChevronRight, null, Modifier.size(14.dp).graphicsLayer { rotationZ = if (open) 90f else 0f }, tint = c.muted)
        }
        if (!folded || open) for (step in if (folded) steps else ToolLine.shown(steps)) {
            val (verb, detail) = ToolLine.parts(step)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.size(12.dp), contentAlignment = Alignment.Center) {
                    when (step.stepState) {
                        StepState.running -> WorkMarkView(WorkMark.Working, 6.dp)
                        StepState.done -> Icon(Icons.Filled.Check, null, Modifier.size(11.dp), tint = c.check)
                        StepState.failed -> Icon(Icons.Filled.Close, null, Modifier.size(11.dp), tint = c.danger)
                    }
                }
                if (step.stepState == StepState.running) Sheen(ToolLine.text(step))
                else androidx.compose.material3.Text(buildAnnotatedString {
                    withStyle(SpanStyle(color = if (step.stepState == StepState.failed) c.danger else c.muted)) { append(verb) }
                    detail?.let { withStyle(SpanStyle(color = c.code, fontFamily = FontFamily.Monospace, fontSize = 12.sp)) { append(" $it") } }
                }, fontSize = Tokens.textMd, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            }
        }
    }
}

/** An artifact's card, resolved from obid when the thread doesn't know it yet. */
@Composable
private fun ArtifactShelf(ref: ArtifactRef) {
    val phone = LocalPhone.current
    LaunchedEffect(ref) { phone.conversation.resolve(ref.id) }
    val artifact = phone.conversation.artifacts[ref.id]
    ArtifactCard(ref, artifact, ref.id in phone.conversation.gone, phone.jobs.firstOrNull { it.id == artifact?.job }?.agentName)
}

/** An artifact under the words that made it (Sangam's `.artifact-card`): its kind's mark, its title, "Page · v2 · made by Oby"; a tap opens the viewer. */
@Composable
fun ArtifactCard(ref: ArtifactRef, artifact: RunnerArtifact?, gone: Boolean, agent: String?) {
    val c = Tokens.c
    var open by remember { mutableStateOf(false) }
    Row(Modifier.fillMaxWidth().background(c.cardFill, RoundedCornerShape(14.dp)).border(1.dp, c.line, RoundedCornerShape(14.dp))
        .clickable(enabled = !gone) { open = true }.padding(horizontal = 12.dp, vertical = 10.dp)
        .semantics { contentDescription = "Open ${artifact?.title ?: "artifact"}, ${artifact?.kindName ?: ""}" }, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Icon(when (artifact?.kind) {
            "html" -> Icons.Outlined.Language; "markdown" -> Icons.Outlined.Description; "image" -> Icons.Outlined.Image
            "pdf" -> Icons.Outlined.PictureAsPdf; "canvas" -> Icons.Outlined.GridView; else -> Icons.Outlined.Description
        }, null, Modifier.size(16.dp), tint = c.muted)
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            FadeText(if (gone) "No longer kept" else artifact?.let { it.title.ifEmpty { "Untitled" } } ?: "Artifact", Tokens.textMd, if (gone) c.muted else c.ink, FontWeight.Medium)
            FadeText(artifact?.line(ref.version, agent) ?: "v${ref.version}", Tokens.textSm, c.muted)
        }
    }
    if (open) ArtifactViewer(ref, artifact, agent) { open = false }
}
