package com.deskree.oby

import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

/**
 * A task as a card in its kind's page (Sangam's TaskCard.tsx): its agent's mark, its title and how
 * long it's been going; its agent, account and repository; then the live step while it runs, the
 * decision while it needs you, what it left behind once done; and its stages as a thin bar. A tap
 * opens its page; holding it offers the ⋮'s actions.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun TaskCard(item: WorkItem) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val job = item.job
    val now = rememberNow()
    val open = rememberOpener()
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var held by remember { mutableStateOf(false) }
    Box {
        Column(Modifier.fillMaxWidth().background(c.chip, RoundedCornerShape(Tokens.cardRadius))
            .combinedClickable(onClick = { phone.push(Route.Task(job.id)) }, onLongClick = { held = true })
            .padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp).semantics { contentDescription = "${job.heading}, ${item.mark.spoken}" }) {
            Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Box(Modifier.width(16.dp).padding(top = 3.dp)) {
                    if (item.mark == WorkMark.New || item.mark == WorkMark.Needs) Box(Modifier.offset((-16).dp, 0.dp)) { WorkMarkView(item.mark) }
                    AgentMark(job.agent, 14.dp)
                }
                T(job.heading, Tokens.textLg, c.ink, FontWeight.SemiBold, Modifier.weight(1f), lines = 2)
                T(TaskFacts.ago(job, now), Tokens.textSm, c.muted)
            }
            T(TaskFacts.meta(job, phone.accountName(job.account)), Tokens.textMd, c.muted, lines = 1, modifier = Modifier.padding(start = 26.dp, top = 4.dp))
            when (item.status) {
                WorkStatus.Running -> Row(Modifier.padding(top = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                    if (job.st == JobStatus.queued) T(job.line, Tokens.textMd, c.text, lines = 1, modifier = Modifier.weight(1f))
                    else Box(Modifier.weight(1f)) { Sheen(job.line.ifEmpty { "Working" }) }
                    if (job.maxRounds > 1) T("Round ${job.currentRound} of ${job.maxRounds}", Tokens.textSm, c.muted)
                }
                WorkStatus.Needs -> Column(Modifier.padding(top = 16.dp)) {
                    HorizontalDivider(color = c.divider)
                    Spacer(Modifier.height(14.dp))
                    val decision = phone.decision(job)
                    val next = job.nextStepOffered
                    when {
                        decision != null -> InboxDecision(decision, inset = false)
                        (job.permissionValue != null && job.isActive) || job.waitsForAnswer -> JobDecision(job, inset = false)
                        next != null -> AskCard(job.needsYouKind, job.line, CardOption.of(listOf(next), 0), happened = job.resumesLine, busy = busy, onChoose = {
                            busy = true
                            scope.launch { problem = try { phone.tell(job.id, Job.TRY_AGAIN); null } catch (e: Exception) { e.message }; busy = false }
                        })
                        else -> {
                            T(job.badge.text, Tokens.textSm, if (job.badge.tone == Tone.Red) c.danger else c.needs, FontWeight.Medium)
                            T(job.line, Tokens.textMd, c.text, modifier = Modifier.padding(top = 4.dp))
                        }
                    }
                }
                WorkStatus.Done -> TaskFacts.resultLine(job)?.let { line ->
                    Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        T(line, Tokens.textSm, c.muted)
                        PublishedLink.url(job.published)?.let { url -> T("Open PR", Tokens.textSm, c.link, FontWeight.Medium, Modifier.clickable { open(url) }) }
                    }
                }
            }
            if (item.status != WorkStatus.Done) Box(Modifier.padding(top = 16.dp)) { StageBar(job, item.status == WorkStatus.Needs) }
            problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 10.dp)) }
        }
        DropdownMenu(held, { held = false }, containerColor = c.surface) {
            DropdownMenuItem({ T("View details", Tokens.textBase, c.ink) }, { held = false; phone.push(Route.Task(job.id)) })
            TaskMenuItems(job, TaskMenu.items(job, phone.conversationOf(job) != null).filter { it != TaskMenu.Item.Move && it != TaskMenu.Item.Mode },
                          close = { held = false }, onProblem = { problem = it })
        }
    }
}

/** The ⋮'s items (Sangam's TaskMenu.tsx): its conversation; Stop task while it goes, Archive once done, Dismiss while it needs you; Move to… and Mode. */
@Composable
fun TaskMenuItems(job: Job, items: List<TaskMenu.Item>, close: () -> Unit, onMove: () -> Unit = {}, onProblem: (String?) -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var modes by remember { mutableStateOf(false) }
    fun run(work: suspend () -> Unit) { close(); scope.launch { onProblem(try { work(); null } catch (e: Exception) { e.message }) } }
    for (item in items) when (item) {
        TaskMenu.Item.OpenConversation -> phone.conversationOf(job)?.let { target ->
            DropdownMenuItem({ T("Open conversation", Tokens.textBase, c.ink) }, { close(); phone.push(Route.Conversation(target.id)) })
        }
        TaskMenu.Item.Stop -> DropdownMenuItem({ T("Stop task", Tokens.textBase, c.danger) }, { run { phone.stop(job.id) } })
        TaskMenu.Item.Archive -> DropdownMenuItem({ T("Archive task", Tokens.textBase, c.ink) }, { close(); phone.archive(job.id) })
        TaskMenu.Item.Dismiss -> DropdownMenuItem({ T("Dismiss", Tokens.textBase, c.ink) }, { run { phone.dismiss(job.id) } })
        TaskMenu.Item.Move -> DropdownMenuItem({ T("Move to…", Tokens.textBase, c.ink) }, { close(); onMove() })
        TaskMenu.Item.Mode -> {
            val mode = RunnerMode.of(job.mode)
            DropdownMenuItem({ T("Mode: ${mode?.label ?: "unknown"}", Tokens.textBase, c.ink) }, { modes = !modes })
            if (modes) for (choice in RunnerMode.entries) DropdownMenuItem({ T("   ${choice.label}" + if (choice == mode) "  ✓" else "", Tokens.textBase, c.ink) },
                                                                         { run { phone.setMode(job.id, choice) } })
        }
    }
}

/** The stages as one thin bar of segments: done and current lit (current pulsing while it works, orange while it needs you), failed in red. */
@Composable
fun StageBar(job: Job, needs: Boolean) {
    val c = Tokens.c
    val stages = job.stages
    if (stages.isEmpty()) return
    val pulse by rememberInfiniteTransition(label = "stage").animateFloat(1f, 0.35f, infiniteRepeatable(tween(800), RepeatMode.Reverse), label = "level")
    Row(Modifier.fillMaxWidth().semantics { contentDescription = job.pipelineValue?.label ?: "" }, horizontalArrangement = Arrangement.spacedBy(3.dp)) {
        for (stage in stages) {
            val color = when (stage.stateName) {
                "done" -> c.stageDone
                "current" -> if (needs) c.needs else c.stageDone
                "failed" -> c.danger
                else -> c.pill
            }
            val live = stage.stateName == "current" && !needs && job.st == JobStatus.running
            Box(Modifier.weight(1f).height(3.dp).graphicsLayer { alpha = if (live) pulse else 1f }.background(color, CircleShape))
        }
    }
}

/**
 * One task on its own page (Sangam's TaskView.tsx with #741's timeline): its title, who has it where
 * and the mode; the decision on top (a failure says what failed); then one card with Result, the
 * Timeline, Usage, Details with the full session, what you asked and its follow-ups. At the foot the
 * box to tell Oby about it, with Stop while it runs.
 */
@Composable
fun TaskPage(id: String) {
    val phone = LocalPhone.current
    val activity = LocalActivity.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    val open = rememberOpener()
    val job = phone.jobs.firstOrNull { it.id == id }
    var looked by remember { mutableStateOf(false) }
    var action by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    var noteProblem by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    var moving by remember { mutableStateOf(false) }
    var session by remember { mutableStateOf(false) }
    var report by remember { mutableStateOf<ResearchDocument?>(null) }

    LaunchedEffect(id) { phone.fetch(id); looked = true }
    DisposableEffect(id) { phone.showing(id, true); phone.markSeen(id); onDispose { phone.showing(id, false); phone.cancelVoice() } }
    fun run(work: suspend () -> Unit) { busy = true; scope.launch { problem = try { work(); null } catch (e: Exception) { e.message }; busy = false } }
    suspend fun publish(job: Job, sentence: String) { action = sentence; open(phone.publish(activity, job.id, sentence)); action = null }
    // The notification's Publish: the action shows, and the fingerprint or face is asked for now.
    LaunchedEffect(phone.publishing, phone.loaded, job != null) {
        if (phone.publishing != id || !phone.loaded || job == null) return@LaunchedEffect
        phone.publishing = null
        if (job.canPublish && !busy) run { publish(job, phone.publishAction(job.id)) }
    }

    Page("", menu = if (job == null) null else {
        {
            MenuButton("Task options") { menu = true }
            DropdownMenu(menu, { menu = false }, containerColor = c.surface) {
                TaskMenuItems(job, TaskMenu.items(job, phone.conversationOf(job) != null), close = { menu = false },
                              onMove = { problem = null; moving = true }, onProblem = { problem = it })
            }
        }
    }) {
        Column(Modifier.fillMaxSize().imePadding()) {
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = Tokens.gutter).padding(top = 4.dp, bottom = 24.dp)) {
                when {
                    job != null -> {
                        JobPageBody(job, phone.decision(job), phone.accounts.firstOrNull { it.id == job.account }?.usage,
                            onSession = { session = true }, onDismiss = { run { phone.dismiss(job.id) } },
                            onAnotherRound = { run { phone.tell(job.id, Job.TRY_AGAIN) } },
                            decision = { phone.decision(job)?.let { InboxDecision(it) } ?: JobDecision(job) },
                            result = {
                                TaskResult(job, action, busy, problem, onPublish = { run { action = phone.publishAction(job.id) } },
                                           onConfirm = { sentence -> run { publish(job, sentence) } }, onNotNow = { action = null; problem = null },
                                           onReport = { run { report = phone.runner.report(job.id) } })
                            },
                            asked = { TaskAsked(job) })
                        Controls(job, busy) { work -> run(work) }
                        if (problem != null && action == null) T(problem!!, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 10.dp))
                    }
                    phone.loaded && looked -> T("This task isn't on the runner any more.", Tokens.textBase, c.text, center = true, modifier = Modifier.fillMaxWidth().padding(top = 80.dp))
                    else -> Box(Modifier.fillMaxWidth().padding(top = 80.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = c.muted) }
                }
            }
            // Every task but Oby's own reviews takes words; the runner picks its session up itself.
            if (job != null && job.reviewOf == null) {
                noteProblem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(horizontal = Tokens.gutter + 12.dp)) }
                Composer(Drafts.task(job.id), "Tell Oby about this task…", enabled = !busy,
                         onStop = if (job.isActive) ({ run { phone.stop(job.id) } }) else null,
                         onSend = { text, _ ->
                             val words = ChatThread.words(text)
                             if (words == null || words.length > 2000) { if (text.length > 2000) noteProblem = "Keep your message under 2,000 characters."; return@Composer }
                             busy = true
                             scope.launch { noteProblem = try { phone.tell(job.id, words); null } catch (e: Exception) { e.message }; busy = false }
                         })
            }
        }
    }
    if (moving && job != null) MoveSheet(job) { moving = false }
    if (session) SessionSheet(id) { session = false }
    report?.let { ReportSheet(it, id) { report = null } }
}

/** What the agent reported, its pull request, what went out, and Publish or Read report. */
@Composable
private fun TaskResult(job: Job, action: String?, busy: Boolean, problem: String?, onPublish: () -> Unit, onConfirm: (String) -> Unit, onNotNow: () -> Unit,
                       onReport: () -> Unit) {
    val c = Tokens.c
    val open = rememberOpener()
    if (job.summary.isNotEmpty()) SelectionContainer { Text(styledSaid(job.summary, c), fontSize = 16.sp, fontWeight = FontWeight.Medium, color = c.ink, lineHeight = 22.sp) }
    job.handoffNote?.let {
        T("Handoff note", Tokens.textSm, c.muted, FontWeight.Medium, Modifier.padding(top = 12.dp))
        SelectionContainer { T(it, Tokens.textMd, c.text, modifier = Modifier.padding(top = 4.dp), lineHeight = 18.sp) }
    }
    val line = TaskFacts.resultLine(job)
    if (line != null) T(line, Tokens.textSm, c.muted, modifier = Modifier.padding(top = 8.dp))
    else job.commits?.takeIf { it > 0 }?.let { T("$it commit${if (it == 1) "" else "s"} on ${job.branch}", Tokens.textSm, c.muted, modifier = Modifier.padding(top = 8.dp)) }
    PublishedLink.url(job.published)?.let { url -> T("Open pull request", Tokens.textSm, c.link, FontWeight.Medium, Modifier.padding(top = 6.dp).clickable { open(url) }) }
    if (job.sent.isNotEmpty()) Box(Modifier.padding(top = 14.dp)) { WentOut(job.sent) }
    job.pullRequestError?.let { T(it, Tokens.textSm, c.muted, modifier = Modifier.padding(top = 6.dp)) }
    if (job.dismissed != null) T("Dismissed. Tell the agent something to pick it up again.", Tokens.textSm, c.muted, modifier = Modifier.padding(top = 6.dp))
    if (job.canPublish) Column(Modifier.padding(top = 12.dp)) {
        // Publish by hand when Oby's own didn't go: the exact action shows first, and exactly that goes out once it's signed.
        job.publishError?.let { T(it, Tokens.textSm, c.needsInk, modifier = Modifier.padding(bottom = 8.dp)) }
        if (action != null) Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
            T(action, Tokens.textBase, c.ink, FontWeight.Medium)
            problem?.let { T(it, Tokens.textSm, c.danger) }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                PillButton(if (busy) "Publishing…" else "Publish with fingerprint", primary = true, enabled = !busy) { onConfirm(action) }
                PillButton("Not now", quiet = true, enabled = !busy, onClick = onNotNow)
            }
        } else PillButton(if (job.published == null) "Publish…" else "Publish the new commits…", primary = true, enabled = !busy, onClick = onPublish)
    }
    if (job.report == true) Box(Modifier.padding(top = 12.dp)) { PillButton("Read report", onClick = onReport) }
}

/** What you asked and told the agent along the way, Tetrix, and its follow-ups. */
@Composable
private fun TaskAsked(job: Job) {
    val phone = LocalPhone.current
    val c = Tokens.c
    PageSection("What you asked") {
        SelectionContainer { T(job.request, Tokens.textBase, c.text, lineHeight = 20.sp) }
        val notes = job.notes.orEmpty()
        if (notes.isNotEmpty()) {
            T("You told the agent", Tokens.textSm, c.label, FontWeight.Medium, Modifier.padding(top = 14.dp))
            for (note in notes) SelectionContainer { T(note, Tokens.textBase, c.text, modifier = Modifier.padding(top = 6.dp)) }
        }
    }
    job.tetrixValue?.takeIf { !it.isEmpty }?.let { PageSection("Tetrix") { TetrixReport(it) } }
    val followUps = ThreadTaskLine.followUps(job.id, phone.jobs)
    if (followUps.isNotEmpty()) PageSection("Follow-ups") {
        followUps.forEachIndexed { i, next ->
            val account = phone.accountName(next.account)
            Column(Modifier.padding(top = if (i == 0) 0.dp else 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                SelectionContainer { T(next.request, Tokens.textBase, c.text, lineHeight = 20.sp) }
                T(ThreadTaskLine.followUp(next, account), Tokens.textMd, c.muted)
                ThreadTask(next, account)
            }
        }
    }
}

/** What applies now, on the page: start now, or use an account past its reserve. The rest is in the ⋮, and Stop in the box. */
@Composable
private fun Controls(job: Job, busy: Boolean, run: (suspend () -> Unit) -> Unit) {
    val phone = LocalPhone.current
    val reserved = if (job.waitsToStart) Usage.liftable(job.waitingValue?.reserved, phone.accounts) else emptyList()
    if (!job.waitsToStart && reserved.isEmpty()) return
    Flow(8.dp, centred = false, modifier = Modifier.padding(top = 4.dp)) {
        if (job.waitsToStart) PillButton("Start now", enabled = !busy) { run { phone.startNow(job.id) } }
        for (account in reserved) PillButton(Usage.useAnyway(account.usage), enabled = !busy) { run { phone.runner.liftReserve(account.id, true) } }
    }
    for (account in reserved) T(Usage.liftNote(account.usage), Tokens.textSm, Tokens.muted, modifier = Modifier.padding(top = 6.dp))
}

/** The page's parts in order: head, decision or failure, then the card with Result, the Timeline, Usage, Details and what you asked. */
@Composable
fun JobPageBody(job: Job, inbox: InboxItem?, account: UsageSnapshot?, onSession: (() -> Unit)?, onDismiss: () -> Unit, onAnotherRound: () -> Unit,
                decision: @Composable () -> Unit, result: @Composable () -> Unit, asked: @Composable () -> Unit) {
    val c = Tokens.c
    val facts = job.facts
    val waits = inbox != null || (job.permissionValue != null && job.isActive) || job.waitsForAnswer
    val failure = (job.st == JobStatus.failed || job.st == JobStatus.interrupted) && job.dismissed == null && !waits
    val now = rememberNow()
    Column(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(verticalAlignment = Alignment.Top) {
                SelectionContainer(Modifier.weight(1f)) { T(job.heading, 22.sp, c.ink, FontWeight.SemiBold, Modifier.semantics { heading() }, lineHeight = 28.sp) }
                T((if (failure) "Failed " else "") + TaskFacts.ago(job, now), Tokens.textSm, c.muted, modifier = Modifier.padding(start = 8.dp, top = 6.dp))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AgentMark(job.agent, 13.dp)
                T(TaskFacts.meta(job, account?.name ?: job.account), Tokens.textMd, c.muted, lines = 1, modifier = Modifier.weight(1f, fill = false))
                T(job.badge.text, Tokens.textSm, tone(job.badge.tone), FontWeight.Medium)
                val mode = RunnerMode.of(job.mode)
                if (job.st != JobStatus.done && mode != null) Row(Modifier.height(22.dp).background(c.pill, CircleShape).padding(start = 9.dp, end = 6.dp)
                    .semantics { contentDescription = "Mode: ${mode.label}. Change it in the task's menu." }, verticalAlignment = Alignment.CenterVertically) {
                    T(mode.label, Tokens.textSm, c.text)
                    Icon(Icons.Filled.ExpandMore, null, Modifier.size(12.dp), tint = c.text)
                }
            }
            job.verdictLine?.let { T(it, Tokens.textSm, c.muted) }
            job.movedLine?.let { T(it, Tokens.textSm, c.muted) }
            job.routineValue?.let { T(it.line, Tokens.textSm, c.muted) }
        }
        if (waits) Box(Modifier.padding(bottom = 8.dp)) { decision() } else if (failure) Box(Modifier.padding(bottom = 8.dp)) {
            val lines = job.summary.split("\n", limit = 2)
            val failing = facts.checks?.lastOrNull()?.failing?.joinToString("\n") { listOfNotNull(it.test, it.message?.let { m -> "  $m" }).joinToString("\n") }
            Box(Modifier.fillMaxWidth().background(c.chip, RoundedCornerShape(Tokens.askRadius)).padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 16.dp)) {
                AskCard("Failed", lines.firstOrNull()?.takeIf { it.isNotEmpty() } ?: job.line, FailedChoice.options(onSession != null), failed = true,
                        happened = lines.getOrNull(1), detail = failing, onChoose = { option ->
                    when (option.answer) {
                        FailedChoice.ROUND -> onAnotherRound()
                        FailedChoice.SESSION -> onSession?.invoke()
                        FailedChoice.DISMISS -> onDismiss()
                    }
                })
            }
        }
        Column(Modifier.fillMaxWidth().background(c.chip, RoundedCornerShape(Tokens.cardRadius)).padding(horizontal = 18.dp)) {
            val hasResult = TaskFacts.hasResult(job) && !failure && (!job.isActive || job.published != null)
            if (hasResult) PageSection("Result", first = true) { result() }
            JobTimeline(job, facts, job.mode, waits && job.isActive, onSession, first = !hasResult)
            if (facts.usage?.tokens != null || facts.usage?.costUsd != null || facts.windowShare != null) {
                PageSection("Usage") { JobUsageLine(facts.usage, facts.windowShare, account, job.st == JobStatus.done) }
            }
            PageSection("Details", accessory = { if (onSession != null) SectionLink("Full session", onSession) }) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    for ((name, value, mono) in TaskFacts.facts(job, job.mode)) Row {
                        T(name, Tokens.textBase, c.muted, modifier = Modifier.width(92.dp))
                        SelectionContainer(Modifier.weight(1f)) { T(value, if (mono) 13.sp else Tokens.textBase, c.text, mono = mono) }
                    }
                }
            }
            asked()
        }
    }
}

@Composable
fun tone(tone: Tone): Color = when (tone) {
    Tone.Orange -> Tokens.needs; Tone.Red -> Tokens.danger; Tone.Green -> Tokens.c.done; Tone.Blue -> Tokens.c.unread; Tone.Gray -> Tokens.muted
}

/** A stage's, a group's or a check's mark. */
@Composable
private fun TimelineMark(mark: TaskFacts.Mark, size: Int = 10) {
    val c = Tokens.c
    Box(Modifier.size((size + 4).dp), contentAlignment = Alignment.Center) {
        when (mark) {
            TaskFacts.Mark.Done -> Box(Modifier.size((size + 4).dp).background(c.done, CircleShape), contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Check, null, Modifier.size((size * 0.9).dp), tint = c.bg)
            }
            TaskFacts.Mark.Current -> WorkMarkView(WorkMark.Working, size.dp)
            TaskFacts.Mark.Needs -> Box(Modifier.size(size.dp).background(c.needs, CircleShape))
            TaskFacts.Mark.Upcoming -> Box(Modifier.size(size.dp).border(1.5.dp, c.check, CircleShape))
            TaskFacts.Mark.Skipped -> Box(Modifier.size(width = size.dp, height = 2.dp).background(c.check, CircleShape))
            TaskFacts.Mark.Failed -> Box(Modifier.size(size.dp).background(c.danger, CircleShape))
        }
    }
}

/**
 * The Timeline (Sangam's #741; "Stages" while obid serves no times): the time track and its basis,
 * then the stages as the page's spine, each with its time, its line, and what hangs off it.
 */
@Composable
private fun JobTimeline(job: Job, facts: JobFacts, mode: String?, needs: Boolean, onSession: (() -> Unit)?, first: Boolean) {
    val c = Tokens.c
    var now by remember { mutableStateOf(Instant.now()) }
    LaunchedEffect(job.isActive) { while (job.isActive) { delay(1000); now = Instant.now() } }
    val timed = facts.estimate != null || facts.stages.isNotEmpty()
    val clock = JobClock.of(job, facts, mode, needs, now)
    val basis = if (clock.phase == JobClock.Phase.Done) null else facts.estimate?.basis
    val aside = if (!timed) null else if (clock.phase == JobClock.Phase.Done) clock.took.replace("estimated", "est.") else clock.aside(compact = true)
    PageSection(if (timed) "Timeline" else "Stages", aside, first) {
        clock.track?.let { TimeTrack(it) }
        basis?.let { Box(Modifier.padding(top = if (clock.track == null) 0.dp else 8.dp)) { BasisLine(it) } }
        val stages = job.stages
        Column(Modifier.padding(top = if (clock.track != null || basis != null) 18.dp else 0.dp)) {
            stages.forEachIndexed { i, stage -> StageRow(job, facts, stage, i == stages.lastIndex, needs, now, onSession) }
        }
    }
}

@Composable
private fun StageRow(job: Job, facts: JobFacts, stage: JobStage, last: Boolean, needs: Boolean, now: Instant, onSession: (() -> Unit)?) {
    val c = Tokens.c
    val mark = TaskFacts.mark(stage.stateName, needs, job.st == JobStatus.running)
    val timing = facts.stages[stage.id]
    Row(Modifier.fillMaxWidth().height(IntrinsicSize.Min), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.width(16.dp).fillMaxHeight(), horizontalAlignment = Alignment.CenterHorizontally) {
            Box(Modifier.height(18.dp), contentAlignment = Alignment.Center) { TimelineMark(mark) }
            if (!last) {
                val dots = c.check
                Canvas(Modifier.width(2.dp).weight(1f).padding(top = 4.dp, bottom = 2.dp)) {
                    var y = 1f
                    while (y < size.height) { drawCircle(dots, 1.dp.toPx(), Offset(size.width / 2, y)); y += 6.dp.toPx() }
                }
            }
        }
        Column(Modifier.weight(1f).padding(bottom = if (last) 0.dp else 18.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.weight(1f)) {
                    if (mark == TaskFacts.Mark.Current) Sheen(stage.title, Tokens.textBase)
                    else T(stage.title, Tokens.textBase, if (mark == TaskFacts.Mark.Failed) c.danger else if (mark == TaskFacts.Mark.Upcoming || mark == TaskFacts.Mark.Skipped) c.text else c.ink, FontWeight.Medium)
                }
                stageTime(job, mark, timing, now)?.let { T(it, Tokens.textSm, c.muted) }
            }
            if (mark == TaskFacts.Mark.Current && job.st == JobStatus.running && job.step.isNotEmpty() && !(stage.detail ?: "").contains(job.step)) {
                Box(Modifier.padding(top = 2.dp)) { Sheen(job.step, Tokens.textBase) }
            }
            stageDetail(job, facts, stage, mark, c)?.let { Text(it, Modifier.padding(top = 2.dp), color = c.muted, fontSize = Tokens.textBase) }
            stageSub(job, facts, mark)?.let { T(it, Tokens.textMd, c.text, modifier = Modifier.padding(top = 2.dp), lineHeight = 17.sp) }
            val reason = stage.reason
            if (reason != null && mark == TaskFacts.Mark.Failed && (job.summary.isEmpty() || !(job.summary.startsWith(reason) || reason.startsWith(job.summary)))) {
                T(reason, Tokens.textMd, c.danger, modifier = Modifier.padding(top = 2.dp))
            }
            when (stage.id) {
                "work" -> WorkInner(facts, mark, now, onSession)
                "check" -> facts.checks?.lastOrNull()?.takeIf { it.steps.isNotEmpty() && mark == TaskFacts.Mark.Current }?.let { StageBox { CheckRows(it.steps) } }
                else -> {}
            }
        }
    }
}

/** "18s" done, "9m" under way, "≈ 3m" to come. */
private fun stageTime(job: Job, mark: TaskFacts.Mark, timing: StageTiming?, now: Instant): String? {
    timing ?: return null
    val waited = timing.waited ?: 0.0
    return when (mark) {
        TaskFacts.Mark.Done, TaskFacts.Mark.Failed -> {
            val s = timing.started ?: return null; val f = timing.finished ?: return null
            JobPageText.seconds(Format.seconds(s, f) - waited)
        }
        TaskFacts.Mark.Current, TaskFacts.Mark.Needs -> timing.started?.let { JobPageText.seconds(Format.seconds(it, now) - waited) }
        TaskFacts.Mark.Upcoming -> {
            val s = timing.started
            if (s != null && job.st == JobStatus.done) JobPageText.seconds(Format.seconds(s, now)) else timing.estimate?.let { "≈ " + JobPageText.seconds((it.low + it.high) / 2) }
        }
        TaskFacts.Mark.Skipped -> null
    }
}

/** The stage's line: the runner's, with what Work left behind once it's done, and what didn't happen after a failure. */
private fun stageDetail(job: Job, facts: JobFacts, stage: JobStage, mark: TaskFacts.Mark, c: ObyColors): AnnotatedString? {
    if (mark == TaskFacts.Mark.Skipped) {
        if (stage.id == "publish" && job.sent.isEmpty()) return AnnotatedString(if (facts.scan?.ran == false) "Nothing went out · the secret scan didn't run, since checks come first" else "Nothing went out")
        if (stage.id == "review" && job.published == null) return AnnotatedString("No pull request to review")
    }
    // On a phone, upcoming stages are just their names and times.
    if (mark == TaskFacts.Mark.Upcoming && job.isActive) return null
    val parts = mutableListOf(stage.detail ?: "")
    if (stage.id == "work" && job.maxRounds <= 1 && parts[0].startsWith("Round 1 of 1")) parts[0] = parts[0].removePrefix("Round 1 of 1").removePrefix(" · ")
    if (stage.id == "work" && job.maxRounds > 1 && !(stage.detail ?: "").startsWith("Round ")) parts.add(0, "Round ${job.currentRound} of ${maxOf(job.currentRound, job.maxRounds)}")
    val diff = if (stage.id == "work" && mark == TaskFacts.Mark.Done) facts.diff else null
    if (stage.id == "work" && mark == TaskFacts.Mark.Done) {
        job.commits?.takeIf { it > 0 }?.let { parts += "$it commit${if (it == 1) "" else "s"}" }
        diff?.files?.let { parts += "$it file${if (it == 1) "" else "s"}" }
    }
    val line = parts.filter { it.isNotEmpty() }.joinToString(" · ")
    if (line.isEmpty() && diff?.added == null && diff?.removed == null) return null
    return buildAnnotatedString {
        append(line)
        if (diff != null && (diff.added != null || diff.removed != null)) {
            if (line.isNotEmpty()) append(" ")
            diff.added?.let { withStyle(SpanStyle(color = c.done)) { append("+$it") } }
            diff.removed?.let { withStyle(SpanStyle(color = c.danger)) { append(" −$it") } }
        }
    }
}

private fun stageSub(job: Job, facts: JobFacts, mark: TaskFacts.Mark): String? {
    if (mark == TaskFacts.Mark.Current || mark == TaskFacts.Mark.Needs) return facts.context
    if (mark != TaskFacts.Mark.Failed) return null
    job.sent.lastOrNull()?.let { return "Stopped here, after: ${it.line}." }
    job.commits?.takeIf { it > 0 }?.let { return "Stopped here. Nothing went out: the ${if (it == 1) "commit stays" else "$it commits stay"} on ${job.branch}." }
    return "Stopped here. Nothing went out."
}

/** Under Work: the counts and the running group while it runs; once done, the counts on one line that opens the session. */
@Composable
private fun WorkInner(facts: JobFacts, mark: TaskFacts.Mark, now: Instant, onSession: (() -> Unit)?) {
    val c = Tokens.c
    val activity = facts.activity ?: return
    val groups = activity.groups.orEmpty()
    if (mark == TaskFacts.Mark.Current) {
        val running = groups.filter { it.running }
        if (activity.counts?.line == null && running.isEmpty()) return
        StageBox {
            activity.counts?.takeIf { it.line != null }?.let { counts ->
                Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    for ((count, label) in counts.chips) Text(buildAnnotatedString {
                        withStyle(SpanStyle(color = c.ink, fontWeight = FontWeight.Medium)) { append("$count") }
                        withStyle(SpanStyle(color = c.text)) { append(" $label") }
                    }, Modifier.height(28.dp).background(c.pill, CircleShape).padding(start = 9.dp, end = 11.dp, top = 5.dp), fontSize = Tokens.textSm)
                }
            }
            for (group in running) Column(Modifier.padding(top = 10.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    TimelineMark(TaskFacts.Mark.Current, 8)
                    FadeText(group.title, Tokens.textBase, c.ink, modifier = Modifier.weight(1f))
                    group.started?.let { T(JobPageText.seconds(Format.seconds(it, group.finished ?: now)), Tokens.textSm, c.muted) }
                }
                for (tool in group.tools.orEmpty().filter { it.running }) Row(Modifier.padding(start = 22.dp, top = 8.dp), verticalAlignment = Alignment.CenterVertically,
                                                                                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TimelineMark(TaskFacts.Mark.Current, 8)
                    Box(Modifier.weight(1f)) { Sheen(tool.summary) }
                    tool.started?.let { T(JobPageText.seconds(Format.seconds(it, now)), Tokens.textSm, c.muted) }
                }
            }
        }
    } else if (mark == TaskFacts.Mark.Done || mark == TaskFacts.Mark.Failed) activity.counts?.line?.let { line ->
        Row(Modifier.padding(top = 8.dp).clickable(enabled = onSession != null) { onSession?.invoke() }, verticalAlignment = Alignment.CenterVertically) {
            T(line, Tokens.textSm, c.muted)
            if (onSession != null) Icon(Icons.Filled.ChevronRight, null, Modifier.size(12.dp), tint = c.muted)
        }
    }
}

@Composable
private fun StageBox(content: @Composable () -> Unit) {
    val c = Tokens.c
    Column(Modifier.padding(top = 10.dp).fillMaxWidth().background(c.cardFill, RoundedCornerShape(14.dp)).border(1.dp, c.line, RoundedCornerShape(14.dp))
        .padding(horizontal = 14.dp, vertical = 12.dp)) { content() }
}

/** The check's commands: each with its mark, the command, what it came to and how long it took. */
@Composable
private fun CheckRows(steps: List<CheckStep>) {
    val c = Tokens.c
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        for (step in steps) {
            val failed = step.passed == false
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                TimelineMark(if (step.running == true) TaskFacts.Mark.Current else if (failed) TaskFacts.Mark.Failed else if (step.passed == true) TaskFacts.Mark.Done else TaskFacts.Mark.Upcoming, 8)
                T(step.command, 12.sp, if (failed) c.danger else c.item, mono = true, lines = 1, modifier = Modifier.weight(1f))
                step.progress?.let { p ->
                    Box(Modifier.size(width = 64.dp, height = 4.dp).background(c.meter, CircleShape)) {
                        Box(Modifier.size(width = (64 * p).dp, height = 4.dp).background(c.stageDone, CircleShape))
                    }
                }
                if (step.progress == null) step.result?.let { T(it, Tokens.textSm, if (failed) c.danger else c.muted, lines = 1) }
                step.seconds?.let { T(JobPageText.seconds(it), Tokens.textSm, c.muted) }
            }
        }
    }
}

/** The time track: what's gone filled, a tick for now, and the finish as a range; orange while paused on you. */
@Composable
private fun TimeTrack(track: JobClock.Track) {
    val c = Tokens.c
    Canvas(Modifier.fillMaxWidth().height(12.dp).semantics { contentDescription = "Time so far and the expected finish" }) {
        val w = size.width; val y = size.height / 2; val h = 6.dp.toPx()
        drawRoundRect(c.meter, Offset(0f, y - h / 2), androidx.compose.ui.geometry.Size(w, h), androidx.compose.ui.geometry.CornerRadius(h / 2))
        val start = if (track.unknown) 0f else (track.rangeStart * w).toFloat()
        val range = if (track.unknown) w else maxOf(4f, ((track.rangeEnd - track.rangeStart) * w).toFloat())
        drawRoundRect(c.check.copy(alpha = if (track.unknown) 0.25f else 0.45f), Offset(start, y - h / 2), androidx.compose.ui.geometry.Size(range, h), androidx.compose.ui.geometry.CornerRadius(h / 2))
        drawRoundRect(if (track.paused) c.needs else c.stageDone, Offset(0f, y - h / 2), androidx.compose.ui.geometry.Size((track.done * w).toFloat(), h), androidx.compose.ui.geometry.CornerRadius(h / 2))
        drawRect(if (track.paused) c.needs else c.ink, Offset((track.done * w).toFloat() - 1, 0f), androidx.compose.ui.geometry.Size(2.dp.toPx(), size.height))
    }
}

/** The usage line: this job's tokens and their API price, then its share of the account's 5-hour and weekly windows. */
@Composable
private fun JobUsageLine(usage: JobUsage?, share: WindowShare?, account: UsageSnapshot?, done: Boolean) {
    val c = Tokens.c
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val parts = listOfNotNull(usage?.tokens?.let { "${JobPageText.tokens(it)} tokens" }, usage?.costUsd?.let { "${JobPageText.dollars(it)} at API prices" })
        if (parts.isNotEmpty()) T(parts.joinToString(" · "), Tokens.textMd, c.text)
        Flow(18.dp, centred = false) {
            account?.fiveHour?.let { UsageWindow("5-hour", it, share?.fiveHour, done) }
            account?.sevenDay?.let { UsageWindow("Week", it, share?.sevenDay, done) }
        }
    }
}

@Composable
private fun UsageWindow(name: String, used: Double, job: Double?, done: Boolean) {
    val c = Tokens.c
    val total = (used * 100).coerceIn(0.0, 100.0)
    val mine = job?.coerceIn(0.0, total)
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        T(name, Tokens.textSm, c.muted)
        Row(Modifier.size(width = 72.dp, height = 4.dp).background(c.meter, CircleShape)) {
            if (mine != null && mine > 0) Box(Modifier.width((72 * mine / 100).dp).height(4.dp).background(c.ink))
            Box(Modifier.width((72 * (total - (mine ?: 0.0)) / 100).dp).height(4.dp).background(c.check))
        }
        Text(buildAnnotatedString {
            append(JobPageText.percent(total))
            if (mine != null) { append(" · this job ${if (done) "used " else ""}"); withStyle(SpanStyle(color = c.ink)) { append("≈ ${JobPageText.percent(mine)}") } }
        }, color = c.muted, fontSize = Tokens.textSm)
    }
}

/** "What went out": each thing Oby sent for the job, with its time. */
@Composable
fun WentOut(outgoing: List<Outgoing>) {
    val c = Tokens.c
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        T("What went out", Tokens.textSm, c.label, FontWeight.Medium, Modifier.padding(bottom = 2.dp))
        for (item in outgoing) Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TimelineMark(TaskFacts.Mark.Done, 8)
            T(item.line, Tokens.textMd, c.muted, modifier = Modifier.weight(1f))
            T(Format.time(item.date), Tokens.textSm, c.muted)
        }
    }
}

/** A job's Tetrix section: what the agent asked it, the session it saved, and where the graph fell short. Plain text throughout. */
@Composable
private fun TetrixReport(report: TetrixJobReport) {
    val c = Tokens.c
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        T(report.callsLine, Tokens.textSm, c.muted)
        if (report.context == true) T("Tetrix's context was ready before it started", Tokens.textSm, c.muted)
        T(if (report.saved.isEmpty()) "No session saved" else "Session saved: " + report.saved.joinToString(", "), Tokens.textSm, c.muted)
        report.gaps?.takeIf { !it.isEmpty }?.let { gaps ->
            T("Where the graph fell short", Tokens.textSm, c.label, FontWeight.Medium, Modifier.padding(top = 10.dp))
            for (gap in gaps.lines) T("• $gap", Tokens.textBase, c.text)
            gaps.sentLine?.let { T(it, Tokens.textSm, c.muted, modifier = Modifier.padding(top = 2.dp)) }
        }
    }
}

/** "Move to…": a tool, one of its accounts with its usage (or the least busy with room), and a model, then what the move will do. */
@Composable
private fun MoveSheet(job: Job, close: () -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var agent by remember { mutableStateOf(job.agent) }
    var account by remember { mutableStateOf<String?>(null) }
    var model by remember { mutableStateOf<String?>(null) }
    var options by remember { mutableStateOf<ModelOptions?>(null) }
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) { options = runCatching { phone.runner.modelOptions() }.getOrNull() }
    val models = when (agent) {
        "claude" -> MoveChoice.claudeModels.map { it to ModelChoice.name(it) }
        "cursor" -> options?.cursor?.models?.map { it.id to it.name }.orEmpty()
        else -> options?.codex?.models?.map { it.id to it.name }?.takeIf { it.isNotEmpty() } ?: listOf(MoveChoice.CODEX_STRONGEST to ModelChoice.name(MoveChoice.CODEX_STRONGEST))
    }
    Dialog(close, DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxWidth().padding(16.dp).background(c.bg, RoundedCornerShape(20.dp)).verticalScroll(rememberScrollState()).padding(16.dp)) {
            T("Move ${job.heading}", 17.sp, c.ink, FontWeight.SemiBold, lines = 2)
            Gap(16)
            SetSegmented(agent, MoveChoice.tools) { agent = it; account = null; model = null }
            Gap(16)
            SetGroup("Account", footer = "Oby never picks an account past 80% of its 5-hour or weekly limit; one you pick takes the job anyway.", rows = buildList {
                add { Choice(if (agent == job.agent) "Keep its account" else "Least busy with room", if (agent == job.agent) null else "Under 80% of its limits", account == null) { account = null } }
                for (item in phone.accounts.filter { it.agent == agent }) add {
                    Choice(item.name, MoveChoice.usage(item.signedIn, item.fiveHour, item.sevenDay), account == item.id, warn = MoveChoice.busy(item.fiveHour, item.sevenDay),
                           enabled = item.signedIn) { account = item.id }
                }
            })
            SetGroup("Model", rows = buildList {
                add { Choice("As it is", job.model?.let(ModelChoice::name), model == null) { model = null } }
                add { Choice("Settings default", null, model == MoveChoice.TOOL_DEFAULT) { model = MoveChoice.TOOL_DEFAULT } }
                for ((id, name) in models) add { Choice(name, null, model == id) { model = id } }
            })
            T(MoveChoice.effect(job.isActive, job.st == JobStatus.running), Tokens.textSm, c.text)
            problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 6.dp)) }
            Row(Modifier.fillMaxWidth().padding(top = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp, Alignment.End)) {
                PillButton("Cancel", quiet = true, onClick = close)
                PillButton(if (busy) "Moving…" else "Move", primary = true, enabled = !busy) {
                    busy = true
                    scope.launch {
                        try { phone.move(job.id, agent, account, model); close() } catch (e: Exception) { problem = e.message }
                        busy = false
                    }
                }
            }
        }
    }
}

@Composable
private fun Choice(title: String, detail: String?, selected: Boolean, warn: Boolean = false, enabled: Boolean = true, pick: () -> Unit) {
    val c = Tokens.c
    Row(Modifier.fillMaxWidth().clickable(enabled = enabled, onClick = pick).heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 8.dp)
        .graphicsLayer { alpha = if (enabled) 1f else 0.4f }, verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            T(title, Tokens.textBase, c.ink)
            detail?.let { T(it, Tokens.textSm, if (warn) c.needs else c.muted) }
        }
        if (selected) Icon(Icons.Filled.Check, null, Modifier.size(18.dp), tint = c.ink)
    }
}

/** A research report, read-only, with explicit, confirmed issue filing. */
@Composable
private fun ReportSheet(report: ResearchDocument, job: String, close: () -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    val open = rememberOpener()
    val clipboard = androidx.compose.ui.platform.LocalClipboardManager.current
    var confirming by remember { mutableStateOf<Pair<ResearchProposal, Boolean>?>(null) }
    var filed by remember { mutableStateOf(mapOf<Int, String>()) }
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    Dialog(close, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(c.bg).windowInsetsPadding(WindowInsets.safeDrawing)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                T("Done", Tokens.textBase, c.ink, FontWeight.Medium, Modifier.clickable(onClick = close).padding(6.dp))
                T("Research report", 16.sp, c.ink, FontWeight.SemiBold, Modifier.weight(1f), center = true)
                T("Copy", Tokens.textBase, c.ink, modifier = Modifier.clickable { clipboard.setText(AnnotatedString(report.markdown)) }.padding(6.dp))
            }
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                T(report.commit.take(12), Tokens.textSm, c.muted, mono = true)
                for (block in MdBlock.blocks(report.markdown)) when (block) {
                    is MdBlock.Heading -> T(block.text, if (block.level == 1) 22.sp else 15.sp, c.ink, FontWeight.SemiBold)
                    is MdBlock.Code -> CodeBox(block.text, Modifier)
                    is MdBlock.Text -> SaidText(block.text, c.item, links = false)
                }
                if (report.proposals.isNotEmpty()) {
                    T("Proposed issues", 18.sp, c.ink, FontWeight.SemiBold)
                    for (proposal in report.proposals) Column(Modifier.fillMaxWidth().background(c.chip, RoundedCornerShape(12.dp)).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        T(proposal.title, Tokens.textLg, c.ink, FontWeight.SemiBold)
                        T(proposal.repo, Tokens.textSm, c.muted)
                        val url = filed[proposal.index] ?: proposal.filed
                        if (url != null) T("Filed issue · Open on GitHub", Tokens.textMd, c.link, modifier = Modifier.clickable { GitHubWork.page(url)?.let(open) })
                        else Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            PillButton("File this issue", enabled = !busy) { confirming = proposal to false }
                            PillButton("File and start", enabled = !busy) { confirming = proposal to true }
                        }
                    }
                }
                problem?.let { T(it, Tokens.textSm, c.danger) }
            }
        }
    }
    confirming?.let { (proposal, start) ->
        AlertDialog(onDismissRequest = { confirming = null }, containerColor = c.surface,
            title = { T("File ‘${proposal.title}’?", 17.sp, c.ink, FontWeight.SemiBold) },
            text = { T("Create in ${proposal.repo}: ${proposal.title}", Tokens.textBase, c.text) },
            confirmButton = { TextButton({
                confirming = null; busy = true
                scope.launch {
                    try { filed = filed + (proposal.index to phone.runner.fileProposal(job, proposal.index, start).issue) } catch (e: Exception) { problem = e.message }
                    busy = false
                }
            }) { T(if (start) "File and start" else "File this issue", Tokens.textBase, c.ink) } },
            dismissButton = { TextButton({ confirming = null }) { T("Cancel", Tokens.textBase, c.muted) } })
    }
}
