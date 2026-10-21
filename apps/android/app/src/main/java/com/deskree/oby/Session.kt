package com.deskree.oby

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.launch

/**
 * A job's live session, full screen (Sangam's SessionView, #786; #785): the agent's words in full by
 * its mark as it writes them, its thinking folded, each tool call a quiet line that opens into what it
 * ran and what came back, your words as bubbles, its to-do list as a checklist, values from the vault
 * as chips with their name. Filters with counts over it; pinned to the live end, with Jump to now.
 */
@Composable
fun SessionSheet(id: String, close: () -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    val job = phone.jobs.firstOrNull { it.id == id }
    val session = remember(id) {
        val runner = phone.runner
        LiveSession(id, { after -> runner.transcript(id, after) }, { n -> runner.transcriptDetail(id, n) })
    }
    DisposableEffect(session) { phone.liveSession = session; onDispose { if (phone.liveSession === session) phone.liveSession = null } }
    LaunchedEffect(session, job?.isActive) { session.follow(job?.isActive == true) }
    var problem by remember { mutableStateOf<String?>(null) }
    var sending by remember { mutableStateOf(false) }
    Dialog(close, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(c.bg).windowInsetsPadding(WindowInsets.safeDrawing).imePadding()) {
            Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(Modifier.width(60.dp))
                T("Session", 16.sp, c.ink, FontWeight.SemiBold, Modifier.weight(1f), center = true)
                T("Done", Tokens.textBase, c.ink, FontWeight.Medium, Modifier.width(60.dp).clickable(onClick = close).padding(6.dp))
            }
            if (job == null) Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) { CircularProgressIndicator(color = c.muted) }
            else {
                Box(Modifier.weight(1f)) { SessionView(session, job.agent, meta(job, phone), job.isActive) }
                problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(horizontal = Tokens.gutter + 12.dp)) }
                Composer(Drafts.task(id), "Tell ${job.agentName}…", enabled = !sending, onSend = { text, _ ->
                    val words = ChatThread.words(text)?.takeIf { it.length <= 2000 } ?: return@Composer
                    sending = true
                    scope.launch { problem = try { phone.tell(id, words); null } catch (e: Exception) { e.message }; sending = false }
                })
            }
        }
    }
}

/** "Claude Code · Opus 5.5 · Personal". */
private fun meta(job: Job, phone: Phone) = listOfNotNull(job.agentName, job.model?.let(ModelChoice::name), phone.accountName(job.account)).filter { it.isNotEmpty() }.joinToString(" · ")

@Composable
private fun SessionView(session: LiveSession, agent: String, meta: String, live: Boolean) {
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var filter by remember { mutableStateOf(TranscriptEntry.Filter.All) }
    val entries = session.entries
    val counts = session.counts
    val shown = if (filter == TranscriptEntry.Filter.All) entries else entries.filter { it.kind == "start" || filter.takes(it) }
    val list = rememberLazyListState()
    val atEnd by remember { derivedStateOf { list.layoutInfo.visibleItemsInfo.lastOrNull()?.index?.let { it >= list.layoutInfo.totalItemsCount - 2 } ?: true } }
    LaunchedEffect(entries.lastOrNull()?.n, entries.lastOrNull()?.words?.length) { if (atEnd && shown.isNotEmpty()) list.scrollToItem(shown.size + 1) }
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val column = maxWidth - Tokens.gutter * 2
        LazyColumn(Modifier.fillMaxSize(), state = list, contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = Tokens.gutter, vertical = 8.dp),
                   verticalArrangement = Arrangement.spacedBy(6.dp)) {
            item("head") {
                Column(Modifier.padding(bottom = 18.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        T(meta, Tokens.textMd, c.muted, lines = 1, modifier = Modifier.weight(1f, fill = false))
                        if (live) Row(Modifier.padding(start = 8.dp), horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                            WorkMarkView(WorkMark.Working)
                            T("Live", Tokens.textMd, c.text)
                        }
                    }
                    Row(Modifier.padding(top = 14.dp).horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        for (tab in TranscriptEntry.Filter.entries.filter { it == TranscriptEntry.Filter.All || (counts[it] ?: 0) > 0 }) {
                            val on = filter == tab
                            Text(buildAnnotatedString {
                                append(tab.label)
                                withStyle(SpanStyle(color = if (on) c.onInk.copy(alpha = 0.55f) else c.muted, fontSize = Tokens.textSm)) { append(" ${counts[tab] ?: 0}") }
                            }, Modifier.heightIn(min = 44.dp).padding(vertical = 8.dp).background(if (on) c.ink else c.pill, CircleShape).clickable { filter = tab }
                                .padding(horizontal = 12.dp, vertical = 5.dp), color = if (on) c.onInk else c.text, fontSize = Tokens.textMd,
                                fontWeight = if (on) FontWeight.Medium else FontWeight.Normal)
                        }
                    }
                }
            }
            if (session.trimmed) item("trimmed") { T("Older entries aren't shown: these are the latest ${LiveSession.MOST}.", Tokens.textSm, c.muted) }
            items(shown, key = { it.n }) { entry -> SessionRow(entry, agent, live && entry.n == session.arriving, session, entry.n == entries.firstOrNull()?.n, column) }
            item("status") {
                when {
                    session.unavailable -> T("This runner doesn't keep this job's session.", Tokens.textSm, c.muted, modifier = Modifier.padding(top = 8.dp))
                    session.failure != null && entries.isEmpty() -> T("The session couldn't be read: ${session.failure}", Tokens.textSm, c.muted, modifier = Modifier.padding(top = 8.dp))
                    entries.isEmpty() && session.loaded -> T("Nothing yet.", Tokens.textSm, c.muted, modifier = Modifier.padding(top = 8.dp))
                    !session.loaded -> CircularProgressIndicator(Modifier.size(16.dp).padding(top = 8.dp), color = c.muted, strokeWidth = 2.dp)
                }
            }
        }
        if (live && !atEnd) Row(Modifier.align(Alignment.BottomCenter).padding(bottom = 12.dp).height(44.dp).background(c.surface, CircleShape)
            .border(1.dp, c.surfaceEdge, CircleShape).clickable { scope.launch { list.animateScrollToItem(shown.size + 1) } }.padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Icon(Icons.Filled.ArrowDownward, null, Modifier.size(14.dp), tint = c.ink)
            T("Jump to now", Tokens.textMd, c.ink)
        }
    }
}

@Composable
private fun SessionRow(entry: TranscriptEntry, agent: String, writing: Boolean, session: LiveSession, first: Boolean, column: androidx.compose.ui.unit.Dp) {
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var open by remember { mutableStateOf(false) }
    var detail by remember { mutableStateOf<TranscriptDetail?>(null) }
    var reading by remember { mutableStateOf(false) }
    when (entry.kind) {
        "start" -> Row(Modifier.fillMaxWidth().padding(top = if (first) 0.dp else 18.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically,
                       horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.weight(1f).height(1.dp).background(c.divider))
            T(entry.words, Tokens.textSm, c.muted, lines = 1)
            entry.at?.let { T(Format.time(it), Tokens.textSm, c.muted) }
            Box(Modifier.weight(1f).height(1.dp).background(c.divider))
        }
        "said" -> Row(Modifier.padding(top = 8.dp, bottom = 4.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.width(22.dp).padding(top = 3.dp).graphicsLayer { alpha = 0.7f }) { AgentMark(agent, 14.dp, c.ink) }
            // Its `code` set apart, as in the conversation; nothing in it opens.
            SelectionContainer(Modifier.weight(1f)) {
                Text(styledSaid(entry.words, c, links = false) + AnnotatedString(if (writing) " ▍" else ""), color = c.item, fontSize = Tokens.textBase, lineHeight = 20.sp)
            }
        }
        "thought" -> Column(Modifier.padding(start = 32.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(Modifier.heightIn(min = 44.dp).clickable { open = !open }, verticalAlignment = Alignment.CenterVertically) {
                T(entry.seconds?.let { "Thought for ${JobPageText.took(it)}" } ?: "Thought", Tokens.textMd, c.muted, italic = true)
                Icon(Icons.Filled.ChevronRight, null, Modifier.size(12.dp).graphicsLayer { rotationZ = if (open) 90f else 0f }, tint = c.muted)
            }
            if (open) Row {
                Box(Modifier.width(2.dp).heightIn(min = 16.dp).background(c.line))
                T(entry.words, Tokens.textMd, c.text, italic = true, modifier = Modifier.padding(start = 10.dp))
            }
        }
        "you" -> Column(Modifier.fillMaxWidth().padding(vertical = 10.dp), horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Bubble(column) { T(entry.words, Tokens.textBase, c.ink) }
            entry.at?.let { T(Format.time(it), 11.sp, c.muted) }
        }
        "plan" -> {
            val todos = entry.todos.orEmpty()
            Column(Modifier.padding(start = 32.dp, top = 4.dp, bottom = 4.dp).fillMaxWidth().background(c.cardFill, RoundedCornerShape(14.dp))
                .border(1.dp, c.line, RoundedCornerShape(14.dp)).padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                T(if (todos.isEmpty()) entry.words else "To do · ${todos.count { it.state == "done" }} of ${todos.size} done", Tokens.textSm, c.label, FontWeight.Medium,
                  Modifier.padding(bottom = 4.dp))
                for (todo in todos) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(12.dp), contentAlignment = Alignment.Center) {
                        if (todo.state == "pending" || todo.state == null) Box(Modifier.size(8.dp).border(1.5.dp, c.check, CircleShape))
                        else WorkMarkView(if (todo.state == "done") WorkMark.Done else WorkMark.Working)
                    }
                    Text(todo.text, color = if (todo.state == "done") c.muted else c.text, fontSize = Tokens.textMd,
                         textDecoration = if (todo.state == "done") TextDecoration.LineThrough else null)
                }
            }
        }
        "asked" -> T(entry.words + (entry.answer?.let { " · $it" } ?: ""), Tokens.textSm, c.muted, modifier = Modifier.padding(start = 32.dp))
        "tool" -> {
            val opens = session.detailServed == true && !entry.running
            val (verb, target) = entry.verbAndTarget
            Column(Modifier.padding(start = 32.dp)) {
                Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).then(if (opens) Modifier.clickable {
                    open = !open
                    if (open && detail == null && !reading) { reading = true; scope.launch { detail = session.detail(entry.n); reading = false } }
                } else Modifier), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Box(Modifier.size(12.dp), contentAlignment = Alignment.Center) {
                        if (entry.failed) Box(Modifier.size(8.dp).background(c.danger, CircleShape)) else WorkMarkView(if (entry.running) WorkMark.Working else WorkMark.Done)
                    }
                    Row(Modifier.weight(1f).fadeOut(), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (entry.running) Sheen(verb) else T(verb, Tokens.textMd, c.muted, lines = 1)
                        target?.let { Text(it, color = c.item, fontSize = 12.sp, fontFamily = FontFamily.Monospace, maxLines = 1, softWrap = false) }
                    }
                    entry.meta?.let { T(it, Tokens.textSm, if (entry.failed) c.danger else c.muted) }
                    entry.seconds?.let { T(JobPageText.took(it), Tokens.textSm, c.muted) }
                    if (opens) Icon(Icons.Filled.ChevronRight, null, Modifier.size(12.dp).graphicsLayer { rotationZ = if (open) 90f else 0f }, tint = c.muted)
                }
                if (open) Box(Modifier.padding(start = 20.dp, top = 6.dp, bottom = 10.dp)) {
                    when {
                        detail != null -> ToolDetail(entry, detail!!)
                        reading -> CircularProgressIndicator(Modifier.size(16.dp), color = c.muted, strokeWidth = 2.dp)
                        else -> T("Its detail couldn't be read.", Tokens.textSm, c.muted)
                    }
                }
            }
        }
        else -> T(entry.words, Tokens.textMd, c.muted, modifier = Modifier.padding(start = 32.dp))
    }
}

/** What a call ran and what came back: an edit's diff, else the command or what it was given, the end of its output, how it ended. */
@Composable
private fun ToolDetail(entry: TranscriptEntry, detail: TranscriptDetail) {
    val c = Tokens.c
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (detail.diff.isNotEmpty()) for ((path, patch) in detail.diff) {
            if (path != null && detail.diff.size > 1) T(path, 12.sp, c.text, mono = true)
            CodeBlock(diff(patch, c))
        } else {
            detail.command?.let { CodeBlock(buildAnnotatedString { withStyle(SpanStyle(color = c.muted)) { append("$ ") }; append(masked(it, c)) }) }
            for (line in detail.given) Text(masked(line, c), color = c.text, fontSize = Tokens.textMd)
            detail.outputText?.takeIf { it.isNotEmpty() }?.let { CodeBlock(masked(it, c)) }
        }
        if (detail.command != null || TranscriptEntry.Filter.of(entry) == TranscriptEntry.Filter.Commands) {
            val parts = mutableListOf<String>()
            (detail.exit ?: entry.exit)?.let { parts += "exit $it" }
            entry.seconds?.let { parts += JobPageText.took(it) }
            val all = detail.lines
            val shownLines = detail.outputText?.split("\n")?.size
            if (all != null && shownLines != null && (all > shownLines || detail.truncated == true)) parts += "the last $shownLines of $all lines"
            if (parts.isNotEmpty()) T(parts.joinToString("   "), Tokens.textSm, c.muted)
        }
    }
}

@Composable
private fun CodeBlock(text: AnnotatedString) {
    val c = Tokens.c
    SelectionContainer(Modifier.fillMaxWidth().heightIn(max = 320.dp).background(c.codeBg, RoundedCornerShape(10.dp)).border(1.dp, c.line, RoundedCornerShape(10.dp))
        .horizontalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 10.dp)) {
        Text(text, color = c.text, fontSize = 12.sp, fontFamily = FontFamily.Monospace, lineHeight = 17.sp, softWrap = false)
    }
}

/** `[vault: NAME]` and `[redacted: rule]` as chips with their name, never the value. */
private fun masked(text: String, c: ObyColors): AnnotatedString = buildAnnotatedString {
    var at = 0
    for (m in Regex("\\[(vault|redacted): [^\\]\\n]+]").findAll(text)) {
        append(text.substring(at, m.range.first))
        withStyle(SpanStyle(color = c.link, background = c.unread.copy(alpha = 0.16f), fontSize = 11.sp, fontFamily = FontFamily.Default)) { append(" ${m.value.drop(1).dropLast(1)} ") }
        at = m.range.last + 1
    }
    append(text.substring(at))
}

/** A unified diff, its added lines green, removed red, hunks quiet. */
private fun diff(patch: String, c: ObyColors): AnnotatedString = buildAnnotatedString {
    patch.split("\n").forEachIndexed { i, line ->
        if (i > 0) append("\n")
        val style = when {
            line.startsWith("@@") -> SpanStyle(color = c.muted)
            line.startsWith("+") && !line.startsWith("+++") -> SpanStyle(color = c.done, background = c.done.copy(alpha = 0.08f))
            line.startsWith("-") && !line.startsWith("---") -> SpanStyle(color = c.danger, background = c.danger.copy(alpha = 0.08f))
            else -> null
        }
        if (style != null) withStyle(style) { append(masked(line, c)) } else append(masked(line, c))
    }
}
