package com.deskree.oby

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import java.time.Instant

/** A decision as a card of its own (radius 18, the chip colour), or bare inside another card. */
@Composable
private fun AskInset(on: Boolean, content: @Composable () -> Unit) {
    if (on) Box(Modifier.fillMaxWidth().background(Tokens.chip, RoundedCornerShape(Tokens.askRadius)).padding(16.dp)) { Column { content() } }
    else Column(Modifier.fillMaxWidth()) { content() }
}

/**
 * One thing only you can answer (`GET /v1/inbox`), as Sangam's decision block: its kind, Oby's
 * headline, what happened, the command or plan, the choices with the recommended one filled, Later,
 * and your own words. Answered here, it goes from the Mac's window too.
 */
@Composable
fun InboxDecision(item: InboxItem, openTask: Boolean = false, inset: Boolean = true) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    val open = rememberOpener()
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    val job = phone.jobs.firstOrNull { it.id == item.job }
    val permission = if (item.kind == "permission") job?.permissionValue else null
    val confirming = item.kind == RunnerConfirm.KIND
    val takesWords = item.job.isNotEmpty() && !confirming
    val waits = phone.waitsToSend(item.id)
    fun run(work: suspend () -> Unit) { busy = true; scope.launch { problem = try { work(); null } catch (e: Exception) { e.message }; busy = false } }
    val words = item.words
    AskInset(inset) {
        AskCard(AskKind.label(item.kind, job?.questionValue?.plan != null), if (confirming) item.title else words.title(item.text),
                CardOption.inbox(item.options, item.kind, job?.questionValue, permission, words, item.details, item.title),
                failed = AskKind.failed(item.kind), source = if (openTask) job?.heading else null,
                happened = if (confirming) InboxWords.plain(item.text) else words.body, behindDetails = if (confirming) null else words.details(item.text),
                detail = if (confirming) item.confirmValue?.words else permission?.detail, plan = if (item.kind == "question") job?.questionValue?.plan else null,
                busy = busy || waits,
                onChoose = { option ->
                    val pr = PublishedLink.url(job?.published)
                    if (option.answer == "Open the PR" && pr != null) open(pr) else run { phone.settle(item.id, answer = option.answer) }
                },
                onLater = { run { phone.settle(item.id, later = Instant.now().plusSeconds(3600)) } })
        if (waits) T(ReachNotice.WAITING, Tokens.textSm, c.muted, modifier = Modifier.padding(top = 10.dp))
        else if (takesWords) OwnWords(if (item.kind == "permission") "No, and tell the agent why…" else "Answer in your own words…", busy) { text ->
            run { if (job != null && permission != null) phone.answer(job, "deny", text) else phone.settle(item.id, answer = text) }
        }
        if (openTask && item.job.isNotEmpty()) T("Open task", Tokens.textSm, c.muted, modifier = Modifier.padding(top = 10.dp).clickable { phone.push(Route.Task(item.job)) })
        problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 8.dp)) }
    }
}

/** A job's own question or permission when the runner has no inbox item for it (an older runner): the same block, answered on the job. */
@Composable
fun JobDecision(job: Job, inset: Boolean = true) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    fun run(work: suspend () -> Unit) { busy = true; scope.launch { problem = try { work(); null } catch (e: Exception) { e.message }; busy = false } }
    val permission = job.permissionValue
    val question = job.questionValue
    if (permission != null && job.isActive) key(permission.id) {
        AskInset(inset) {
            AskCard("Permission", permission.title, CardOption.permission(permission), detail = permission.detail, busy = busy,
                    onChoose = { option -> run { phone.answer(job, option.answer) } })
            OwnWords("No, and tell the agent why…", busy) { text -> run { phone.answer(job, "deny", text) } }
            problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 8.dp)) }
        }
    } else if (job.waitsForAnswer && question != null) key(question.text) {
        AskInset(inset) {
            AskCard(AskKind.label("question", question.plan != null), question.text, question.cardOptions, plan = question.plan, busy = busy,
                    onChoose = { option -> run { phone.tell(job.id, option.answer) } })
            OwnWords("Answer in your own words…", busy) { text -> run { phone.tell(job.id, text) } }
            problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 8.dp)) }
        }
    }
}

/** Under a decision: your own words instead of a choice, sent with the arrow. */
@Composable
private fun OwnWords(prompt: String, busy: Boolean, send: (String) -> Unit) {
    val c = Tokens.c
    var words by remember { mutableStateOf("") }
    val typed = ChatThread.words(words)
    fun go() { typed?.let { send(it); words = "" } }
    Row(Modifier.padding(top = 12.dp).fillMaxWidth().heightIn(min = 36.dp).border(1.dp, c.line, RoundedCornerShape(18.dp)).padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 4.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        BasicTextField(words, { words = it }, Modifier.weight(1f).semantics { contentDescription = prompt }, enabled = !busy, maxLines = 4,
            textStyle = TextStyle(color = c.ink, fontSize = Tokens.textMd), cursorBrush = SolidColor(c.ink),
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Send), keyboardActions = KeyboardActions(onSend = { go() }),
            decorationBox = { inner -> Box { if (words.isEmpty()) T(prompt, Tokens.textMd, c.muted); inner() } })
        if (typed != null) Box(Modifier.size(28.dp).background(c.active, CircleShape).clickable(enabled = !busy) { go() }.semantics { contentDescription = "Send your answer" },
                               contentAlignment = Alignment.Center) { Icon(Icons.Filled.ArrowUpward, null, Modifier.size(15.dp), tint = c.ink) }
    }
}

/**
 * A kind's To do tab (Review PR and Issues): Connect GitHub while gh is signed out, then the items
 * no job works on yet by board column, then what obid cut and why its last read of GitHub failed.
 */
@Composable
fun GitHubToDo(kind: WorkType, work: GitHubWork?, columns: List<GitHubWork.Column>, signedOut: Boolean) {
    val phone = LocalPhone.current
    val c = Tokens.c
    if (signedOut) ConnectGitHubCard()
    val named = columns.any { it.name != null }
    val projects = columns.mapNotNull { it.project }.toSet().size > 1
    for (column in columns) {
        if (named) T(column.name?.let { name -> if (projects) column.project?.let { "$name · $it" } ?: name else name } ?: "Not on a board",
                     Tokens.textSm, c.muted, FontWeight.Medium, Modifier.padding(horizontal = 4.dp).padding(top = 8.dp))
        for (item in column.items) GitHubCard(item, start = { phone.startGitHubWork(item.id) }, later = { phone.gitHubLater = phone.gitHubLater + item.id })
    }
    for (line in work?.cut(kind).orEmpty()) T(line, Tokens.textSm, c.muted, modifier = Modifier.padding(horizontal = 4.dp))
    work?.error?.let { T(GitHubWork.plain(it), Tokens.textSm, c.muted, modifier = Modifier.padding(horizontal = 4.dp)) }
    if (columns.isEmpty() && !signedOut) T("Nothing to do", Tokens.textBase, c.muted, modifier = Modifier.padding(vertical = 8.dp, horizontal = 4.dp))
}

/** A GitHub item waiting to start (Sangam's TaskCard with its "Start it?" decision): one tap starts Oby's job, Open on GitHub, and Later. */
@Composable
private fun GitHubCard(item: GitHubWork.Item, start: suspend () -> Unit, later: () -> Unit) {
    val c = Tokens.c
    val open = rememberOpener()
    val scope = rememberCoroutineScope()
    val now = rememberNow()
    var busy by remember { mutableStateOf(false) }
    var problem by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxWidth().background(c.chip, RoundedCornerShape(Tokens.cardRadius)).padding(start = 20.dp, end = 20.dp, top = 18.dp, bottom = 20.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Icon(painterResource(R.drawable.mark_github), "GitHub", Modifier.size(16.dp).padding(top = 2.dp), tint = c.muted)
            Text(buildAnnotatedString {
                item.who?.let { withStyle(SpanStyle(color = c.muted)) { append("$it  ") } }
                withStyle(SpanStyle(color = c.ink)) { append(item.heading) }
            }, Modifier.weight(1f), fontSize = Tokens.textLg, fontWeight = FontWeight.SemiBold, maxLines = 2)
            item.updated?.let { T(TaskFacts.duration(Format.seconds(it, now)), Tokens.textSm, c.muted) }
        }
        Row(Modifier.padding(start = 26.dp, top = 4.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            T(item.repoName, Tokens.textMd, c.muted, lines = 1)
            item.column?.let { T(it, Tokens.textSm, c.text, lines = 1, modifier = Modifier.background(c.pill, CircleShape).padding(horizontal = 8.dp, vertical = 2.dp)) }
        }
        Spacer(Modifier.height(16.dp))
        HorizontalDivider(color = c.divider)
        Spacer(Modifier.height(14.dp))
        AskCard(item.label, item.headline,
                (item.action?.let { listOf(CardOption(it, it, recommended = true)) } ?: emptyList()) +
                    (if (item.page == null) emptyList() else listOf(CardOption("Open on GitHub", "open"))),
                happened = item.note, busy = busy, onLater = later, explains = false,
                onChoose = { option ->
                    if (option.answer == "open") item.page?.let(open) else {
                        busy = true
                        scope.launch { problem = try { start(); null } catch (e: Exception) { e.message }; busy = false }
                    }
                })
        problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 8.dp)) }
    }
}

/** Connect GitHub, at the top of Review PR and Issues while obid's gh is signed out. GitHub's sign-in is the Mac's alone. */
@Composable
private fun ConnectGitHubCard() {
    val c = Tokens.c
    Column(Modifier.fillMaxWidth().background(c.chip, RoundedCornerShape(Tokens.cardRadius)).padding(20.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(10.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(painterResource(R.drawable.mark_github), null, Modifier.size(16.dp), tint = c.muted)
            T("Connect GitHub", Tokens.textLg, c.ink, FontWeight.SemiBold)
        }
        T("See the pull requests waiting for your review and the issues assigned to you here, and hand any of them to Oby in one tap. Connect GitHub on your Mac, in Settings › Connectors.",
          Tokens.textMd, c.text, modifier = Modifier.padding(top = 8.dp))
    }
}

/** A routine waiting for its next run, on Home's Routines page (Sangam's "Starts Monday at 9"). */
@Composable
fun UpcomingRoutineCard(routine: RunnerRoutine) {
    val c = Tokens.c
    Column(Modifier.fillMaxWidth().background(c.chip, RoundedCornerShape(Tokens.cardRadius)).padding(horizontal = 20.dp, vertical = 18.dp),
           verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            T(routine.name, Tokens.textLg, c.ink, FontWeight.SemiBold, Modifier.weight(1f), lines = 2)
            WorkMarkView(WorkMark.Queued)
        }
        T("${routine.repoName} · ${routine.`when`}", Tokens.textMd, c.muted, lines = 1)
        routine.starts()?.let { T(it, Tokens.textMd, c.muted) }
    }
}
