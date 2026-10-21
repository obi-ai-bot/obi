package com.deskree.oby

import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.wrapContentHeight
import androidx.compose.ui.draw.rotate
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Forum
import androidx.compose.material.icons.filled.Forum
import androidx.compose.material.icons.outlined.Home
import androidx.compose.material.icons.filled.Home
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.WindowInsets
import android.view.ViewGroup
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ViewSidebar
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.time.Instant

val LocalCharacter = staticCompositionLocalOf<ObyCharacter?> { null }

/** "Now", ticking every `seconds`: what a line saying how long ago reads. */
@Composable
fun rememberNow(seconds: Long = 30): Instant = produceState(Instant.now()) { while (true) { delay(seconds * 1000); value = Instant.now() } }.value

/**
 * Home (Sangam's Home.tsx, apps/ios/app/Home.swift): Oby on its stage, what's running and what needs
 * you under it, a chip for every kind of work, then the running tasks and the latest conversations,
 * and the message box. What you send there starts a conversation and opens it.
 */
@Composable
fun HomeView() {
    val phone = LocalPhone.current
    val c = Tokens.c
    val work = phone.work
    val running = work.count { it.status == WorkStatus.Running }
    val needs = WorkList.needsYou(work, phone.loose.size)
    val owner = HomeLine.owner(phone.link?.name)
    Column(Modifier.fillMaxSize().imePadding()) {
        Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clickable { phone.panel = PanelSection.Home }.semantics { contentDescription = "Show sidebar" }, contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Outlined.ViewSidebar, null, Modifier.graphicsLayer { scaleX = -1f }, tint = c.ink)
            }
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(44.dp).clickable { phone.push(Route.Settings) }.semantics { contentDescription = "Settings" }, contentAlignment = Alignment.Center) {
                OwnerPicture(owner)
            }
        }
        val scope = rememberCoroutineScope()
        var refreshing by remember { mutableStateOf(false) }
        PullToRefreshBox(refreshing, { scope.launch { refreshing = true; phone.reload(); refreshing = false } }, Modifier.weight(1f)) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Tokens.gutter).padding(top = 6.dp, bottom = 16.dp),
                   horizontalAlignment = Alignment.CenterHorizontally) {
                Stage()
                T(HomeLine.attention(running, needs), Tokens.textBase, if (running + needs == 0) c.text else c.muted, center = true,
                  modifier = Modifier.padding(top = 14.dp).then(if (needs > 0) Modifier.clickable { PhoneWork.firstNeeding(work, phone.answering)?.let(phone::push) } else Modifier))
                Flow(8.dp, modifier = Modifier.widthIn(max = 362.dp).padding(top = 16.dp).semantics { contentDescription = "Your tasks" }) {
                    for (group in WorkList.kinds(work)) HomeChip(group.label, group.fresh, group.needs > 0) { group.type?.let { phone.push(Route.Kind(it)) } }
                }
                Column(Modifier.fillMaxWidth().padding(top = 22.dp)) {
                    val rows = PhoneWork.running(work)
                    val recent = phone.conversations?.let(PhoneWork::recent).orEmpty()
                    if (rows.isNotEmpty()) {
                        ListLabel("Running", "See all") { phone.push(Route.All) }
                        for (item in rows) HomeTaskRow(item, PhoneWork.step(item, phone.decision(item.job))) { phone.push(Route.Task(item.id)) }
                    }
                    if (recent.isNotEmpty()) {
                        if (rows.isNotEmpty()) Spacer(Modifier.height(14.dp))
                        ListLabel("Recent", "All conversations") { phone.panel = PanelSection.Conversations }
                        for (conversation in recent) {
                            LaunchedEffect(conversation.id) { phone.preview(conversation.id) }
                            HomeConversationRow(conversation, conversation.turn?.text ?: phone.previews[conversation.id]) { phone.push(Route.Conversation(conversation.id)) }
                        }
                    }
                }
            }
        }
        Composer(Drafts.HOME, HomeLine.placeholder(owner ?: ""), onSend = { text, spoken ->
            phone.ask(text, spoken, new = true)
            phone.push(Route.NewConversation)
        })
    }
}

/** Oby on its stage: the character's page, white in both themes, drawing only while Home shows. */
@Composable
private fun Stage() {
    val phone = LocalPhone.current
    val character = LocalCharacter.current ?: return
    val mood = when {
        phone.talk is Phone.Talk.Thinking -> "thinking"
        phone.active.any { it.isWorking } -> "working"
        else -> "idle"
    }
    LaunchedEffect(mood) { character.mood = mood }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle) {
        character.pause(!lifecycle.currentState.isAtLeast(Lifecycle.State.STARTED))
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_START) character.pause(false)
            if (event == Lifecycle.Event.ON_STOP) character.pause(true)
        }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer); character.pause(true) }
    }
    AndroidView({ character.view.also { (it.parent as? ViewGroup)?.removeView(it) } },
                Modifier.size(width = 160.dp, height = 157.dp).graphicsLayer { alpha = if (character.ready) 1f else 0f }.semantics { contentDescription = "Oby" })
}

@Composable
private fun ListLabel(title: String, more: String, onMore: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(26.dp).padding(horizontal = 0.dp), verticalAlignment = Alignment.CenterVertically) {
        T(title, Tokens.textSm, Tokens.label, modifier = Modifier.weight(1f).semantics { heading() })
        T(more, Tokens.textSm, Tokens.label, modifier = Modifier.clickable(onClick = onMore).padding(vertical = 4.dp))
    }
}

/** A running task on Home (`.task-row`): its agent's mark, its title, what it's on, its mark. */
@Composable
private fun HomeTaskRow(item: WorkItem, step: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(48.dp).clickable(onClick = onClick), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) { AgentMark(item.job.agent, 13.dp, Tokens.ink.copy(alpha = 0.7f)) }
        Column(Modifier.weight(1f)) {
            FadeText(item.job.heading, Tokens.textBase, Tokens.item)
            T(step, Tokens.textSm, Tokens.muted, lines = 1)
        }
        WorkMarkView(item.mark)
    }
}

@Composable
private fun HomeConversationRow(conversation: RunnerConversation, last: String?, onClick: () -> Unit) {
    val now = rememberNow(60)
    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable(onClick = onClick).padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            FadeText(conversation.title.ifEmpty { "Conversation" }, Tokens.textBase, Tokens.item)
            if (!last.isNullOrEmpty()) FadeText(last, Tokens.textSm, Tokens.muted)
        }
        if (conversation.latest > Instant.EPOCH) T(ConversationOrder.ago(conversation.latest, now), Tokens.textSm, Tokens.muted, modifier = Modifier.padding(top = 6.dp))
    }
}

/** A kind of work's chip on Home: a blue dot while it holds a new task, an orange one when something in it needs you. */
@Composable
fun HomeChip(label: String, fresh: Boolean, needs: Boolean, onClick: () -> Unit) {
    val c = Tokens.c
    Row(Modifier.height(34.dp).clip(CircleShape).background(c.pill).clickable(onClick = onClick).padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        if (fresh || needs) Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            if (fresh) Box(Modifier.size(6.dp).background(c.unread, CircleShape).semantics { contentDescription = "New" })
            if (needs) Box(Modifier.size(6.dp).background(c.needs, CircleShape).semantics { contentDescription = "Needs you" })
        }
        T(label, Tokens.textBase, c.text, lines = 1)
    }
}

/**
 * One kind of work's page (Sangam's GroupView.tsx): its name, Running and Completed tabs with their
 * counts (Review PR and Issues have To do first, for GitHub's items no job works on yet), a card per
 * task under the open tab, and under Completed the way to Archived.
 */
@Composable
fun KindPage(kind: WorkType) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val gitHub = kind == WorkType.Review || kind == WorkType.Issues
    val work = phone.gitHubWork
    val signedOut = gitHub && work != null && !work.signedIn
    val upcoming = if (kind == WorkType.Routines) RunnerRoutine.upcoming(phone.routines) else emptyList()
    val toDo = if (gitHub) work?.toDo(kind, phone.gitHubLater).orEmpty() else emptyList()
    val opensOnToDo = gitHub && (toDo.isNotEmpty() || signedOut)
    val items = WorkList.ranked(phone.work.filter { it.type == kind })
    var picked by rememberSaveable(kind.id) { mutableStateOf<String?>(null) }
    LaunchedEffect(kind.id, work == null) { if (picked == null && (!gitHub || work != null)) picked = WorkList.firstTab(items, opensOnToDo).name }
    LaunchedEffect(kind.id) { if (gitHub) phone.refreshGitHubWork() }
    val tab = picked?.let { WorkTab.valueOf(it) } ?: WorkList.firstTab(items, opensOnToDo)
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    Page("") {
        PullToRefreshBox(refreshing, { scope.launch { refreshing = true; phone.reload(); refreshing = false } }) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Tokens.gutter).padding(top = 8.dp, bottom = 32.dp),
                   verticalArrangement = Arrangement.spacedBy(8.dp)) {
                T(kind.label, 28.sp, c.ink, FontWeight.SemiBold, Modifier.padding(bottom = 12.dp).semantics { heading() })
                LineTabs(tab, WorkList.counts(items, if (gitHub) toDo.sumOf { it.items.size } else null, upcoming.size)) { picked = it.name }
                Gap(4)
                val cards = WorkList.items(items, tab)
                if (tab == WorkTab.Todo) GitHubToDo(kind, work, toDo, signedOut)
                if (tab == WorkTab.Running) for (routine in upcoming) UpcomingRoutineCard(routine)
                for (item in cards) TaskCard(item)
                if (tab != WorkTab.Todo && cards.isEmpty() && (tab == WorkTab.Done || upcoming.isEmpty())) {
                    T(if (tab == WorkTab.Done) "Nothing completed yet" else "Nothing running", Tokens.textBase, c.muted, modifier = Modifier.padding(vertical = 8.dp, horizontal = 4.dp))
                }
                if (tab == WorkTab.Done) T("Older ones are in Archived", Tokens.textSm, c.muted, modifier = Modifier.padding(top = 8.dp, start = 4.dp).clickable { phone.push(Route.Archived) })
            }
        }
    }
}

/** Every task Home lists (Sangam's side panel): by kind of work or by status, each group's done ones capped behind Show more; Clear done, and Archived. */
@Composable
fun AllTasksPage() {
    val phone = LocalPhone.current
    val c = Tokens.c
    val prefs = Store.prefs(LocalActivity.current)
    var groupBy by remember { mutableStateOf(GroupBy.valueOf(prefs.getString("ObyGroupBy", "Type") ?: "Type")) }
    var more by remember { mutableStateOf(setOf<String>()) }
    var problem by remember { mutableStateOf<String?>(null) }
    var menu by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val groups = WorkList.groups(phone.work, groupBy)
    Page("Tasks", menu = {
        MenuButton("Group by") { menu = true }
        DropdownMenu(menu, { menu = false }, containerColor = c.surface) {
            T("Group by", Tokens.textSm, c.muted, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
            for (g in GroupBy.entries) DropdownMenuItem({ T(g.label + if (g == groupBy) "  ✓" else "", Tokens.textBase, c.ink) }, {
                groupBy = g; prefs.edit().putString("ObyGroupBy", g.name).apply(); menu = false
            })
            HorizontalDivider(color = c.line)
            // Through the runner (it keeps the time), so the Mac's window clears too.
            DropdownMenuItem({ T("Clear done", Tokens.textBase, c.ink) }, {
                menu = false
                scope.launch { problem = try { phone.clear(); null } catch (e: Exception) { e.message } }
            }, enabled = phone.visibleJobs.any { it.clearable() })
        }
    }) {
        LazyColumn(Modifier.fillMaxSize().padding(horizontal = Tokens.gutter)) {
            if (groups.isEmpty()) item { T(if (phone.loaded) "Nothing yet. Ask Oby for something on Home." else "Reaching the runner…", Tokens.textBase, c.muted, modifier = Modifier.padding(vertical = 12.dp)) }
            for (group in groups) {
                val (rows, hidden) = WorkList.shown(group, group.id in more)
                item(group.id) {
                    T("${group.label} · ${group.count} ${group.countLabel}", Tokens.textMd, c.item, FontWeight.Medium, Modifier.padding(top = 18.dp, bottom = 8.dp))
                }
                item(group.id + ":rows") {
                    Column(Modifier.fillMaxWidth().background(c.surface, RoundedCornerShape(12.dp)).padding(horizontal = 14.dp, vertical = 4.dp)) {
                        for (row in rows) TaskRow(row) { phone.push(Route.Task(row.id)) }
                        if (hidden > 0) T(if (group.id in more) "Show less" else "Show $hidden more", Tokens.textMd, c.muted,
                                          modifier = Modifier.fillMaxWidth().clickable { more = if (group.id in more) more - group.id else more + group.id }.padding(vertical = 10.dp))
                    }
                }
            }
            item {
                Column(Modifier.padding(top = 18.dp, bottom = 32.dp)) {
                    T("Archived", Tokens.textBase, c.ink, modifier = Modifier.fillMaxWidth().background(c.surface, RoundedCornerShape(12.dp)).clickable { phone.push(Route.Archived) }.padding(14.dp))
                    problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(top = 8.dp)) }
                }
            }
        }
    }
}

/** A task in a list: its agent's mark, its title, how long ago, and its mark. */
@Composable
private fun TaskRow(item: WorkItem, onClick: () -> Unit) {
    val now = rememberNow()
    Row(Modifier.fillMaxWidth().heightIn(min = 40.dp).clickable(onClick = onClick), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) { AgentMark(item.job.agent, 13.dp) }
        T(item.job.heading, Tokens.textBase, if (item.status == WorkStatus.Done) Tokens.c.doneTitle else Tokens.c.openTitle, lines = 1, modifier = Modifier.weight(1f))
        T(TaskFacts.ago(item.job, now), Tokens.textSm, Tokens.muted)
        WorkMarkView(item.mark)
    }
}

/** Archived (Sangam's ArchiveView.tsx), kept by this phone: the done tasks that left Home, most recently done first, with a search. */
@Composable
fun ArchivedPage() {
    val phone = LocalPhone.current
    val c = Tokens.c
    var query by remember { mutableStateOf("") }
    val all = phone.archived.sortedByDescending { it.finished ?: it.created }
    val q = query.trim()
    val shown = all.filter { q.isEmpty() || "${it.heading} ${it.agentName} ${it.repoName}".contains(q, ignoreCase = true) }
    Page("Archived") {
        Column(Modifier.fillMaxSize().padding(horizontal = Tokens.gutter)) {
            SearchField(query, "Search archived tasks") { query = it }
            LazyColumn(Modifier.fillMaxSize().padding(top = 8.dp)) {
                items(shown, key = { it.id }) { job ->
                    Row(Modifier.fillMaxWidth().heightIn(min = 52.dp).clickable { phone.push(Route.Task(job.id)) }, verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) { AgentMark(job.agent, 13.dp) }
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            T(job.heading, Tokens.textBase, c.item, lines = 1)
                            T(TaskFacts.meta(job, phone.accountName(job.account)), Tokens.textSm, c.muted, lines = 1)
                        }
                        T(ConversationOrder.ago(job.finished ?: job.created), Tokens.textSm, c.muted)
                    }
                }
                if (shown.isEmpty()) item { T(if (all.isEmpty()) "Nothing archived yet" else "Nothing archived matches “$q”", Tokens.textBase, c.muted, modifier = Modifier.padding(vertical = 12.dp)) }
            }
        }
    }
}

@Composable
fun SearchField(text: String, prompt: String, onChange: (String) -> Unit) {
    val c = Tokens.c
    Row(Modifier.fillMaxWidth().height(40.dp).background(c.field, RoundedCornerShape(10.dp)).border(1.dp, c.line, RoundedCornerShape(10.dp)).padding(horizontal = 10.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Filled.Search, null, Modifier.size(16.dp), tint = c.muted)
        BasicTextField(text, onChange, Modifier.weight(1f).semantics { contentDescription = prompt }, singleLine = true,
                       textStyle = TextStyle(color = c.ink, fontSize = Tokens.textBase), cursorBrush = SolidColor(c.ink),
                       decorationBox = { inner -> Box { if (text.isEmpty()) T(prompt, Tokens.textBase, c.muted); inner() } })
    }
}

/** The Inbox (docs/oby-ux.md row 10): what only you can answer and has no task on Home, the longest-waiting first. */
@Composable
fun InboxPage() {
    val phone = LocalPhone.current
    val c = Tokens.c
    val now = rememberNow()
    val items = PhoneWork.loose(InboxItem.waiting(phone.inbox, now), phone.work)
    val scope = rememberCoroutineScope()
    var refreshing by remember { mutableStateOf(false) }
    Page("") {
        PullToRefreshBox(refreshing, { scope.launch { refreshing = true; phone.reload(); refreshing = false } }) {
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Tokens.gutter).padding(top = 8.dp, bottom = 32.dp),
                   verticalArrangement = Arrangement.spacedBy(12.dp)) {
                T("Inbox", 28.sp, c.ink, FontWeight.SemiBold, Modifier.padding(bottom = 8.dp).semantics { heading() })
                for (item in items) Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    T(item.line(now), Tokens.textSm, c.muted, lines = 1)
                    InboxDecision(item, openTask = true)
                }
                if (items.isEmpty()) T("Nothing needs you", Tokens.textBase, c.muted)
            }
        }
    }
}

// MARK: The side panel (apps/ios/app/SidePanel.swift)

/** The panel (Sangam's Sidebar.tsx, on a phone): the icon strip on the far left, the column beside it showing one section. */
@Composable
fun SidePanel(close: () -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val section = phone.panel ?: PanelSection.Home
    fun open(route: Route) { phone.homePath = listOf(route); phone.panel = null }
    Row(Modifier.fillMaxSize().background(c.bg).windowInsetsPadding(WindowInsets.safeDrawing)) {
        Column(Modifier.width(Tokens.rail).fillMaxSize().padding(vertical = 8.dp), horizontalAlignment = Alignment.CenterHorizontally,
               verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Strip(section == PanelSection.Home, "Home", Icons.Filled.Home, Icons.Outlined.Home) { phone.panel = PanelSection.Home }
            Strip(section == PanelSection.Conversations, "Conversations", Icons.Filled.Forum, Icons.Outlined.Forum) { phone.panel = PanelSection.Conversations }
            Spacer(Modifier.weight(1f))
            Box(Modifier.size(44.dp).clickable { open(Route.Settings) }.semantics { contentDescription = "Settings" }, contentAlignment = Alignment.Center) {
                OwnerPicture(HomeLine.owner(phone.link?.name))
            }
        }
        Box(Modifier.width(1.dp).fillMaxSize().background(c.edge))
        Column(Modifier.weight(1f)) {
            Row(Modifier.fillMaxWidth().padding(start = 12.dp, end = 4.dp, top = 4.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                T(if (section == PanelSection.Home) "Home" else "Conversations", Tokens.textTitle, c.ink, FontWeight.SemiBold, Modifier.weight(1f).semantics { heading() })
                Box(Modifier.size(44.dp).clickable(onClick = close).semantics { contentDescription = "Hide sidebar" }, contentAlignment = Alignment.Center) {
                    Icon(Icons.AutoMirrored.Outlined.ViewSidebar, null, Modifier.size(20.dp).graphicsLayer { scaleX = -1f }, tint = c.muted)
                }
            }
            when (section) {
                PanelSection.Home -> TasksColumn(::open)
                PanelSection.Conversations -> ConversationsColumn(::open)
            }
        }
    }
}

@Composable
private fun Strip(on: Boolean, label: String, filled: androidx.compose.ui.graphics.vector.ImageVector, outlined: androidx.compose.ui.graphics.vector.ImageVector, onClick: () -> Unit) {
    val c = Tokens.c
    Box(Modifier.size(44.dp).clickable(onClick = onClick).semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(36.dp).background(if (on) c.active else androidx.compose.ui.graphics.Color.Transparent, RoundedCornerShape(Tokens.iconRadius)), contentAlignment = Alignment.Center) {
            Icon(if (on) filled else outlined, null, Modifier.size(20.dp), tint = if (on) c.ink else c.railIcon)
        }
    }
}

/** Home's tasks in the panel (Sangam's side panel grouped by kind): each kind's open tasks and its latest done ones; the Inbox, every task and Archived. */
@Composable
private fun TasksColumn(open: (Route) -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val groups = WorkList.groups(phone.work, GroupBy.Type)
    LazyColumn(Modifier.fillMaxSize()) {
        if (groups.isEmpty()) item { T(if (phone.loaded) "Nothing yet. Ask Oby for something on Home." else "Reaching your Mac…", Tokens.textBase, c.muted, modifier = Modifier.padding(horizontal = 12.dp)) }
        for (group in groups) {
            val folded = group.id in phone.panelFolded
            item(group.id) {
                // A kind's name opens its page, as Home's chip does (the owner's addition to Sangam's
                // design, 2026-10-21); the chevron and the rest of the row fold it.
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).height(IntrinsicSize.Min), verticalAlignment = Alignment.CenterVertically) {
                    group.type?.let { kind ->
                        T(group.label, Tokens.textSm, c.label, modifier = Modifier.fillMaxHeight()
                            .clickable(onClickLabel = "Open ${group.label}") { open(Route.Kind(kind)) }
                            .semantics { contentDescription = "Open ${group.label}"; heading() }
                            .padding(start = 12.dp, end = 6.dp).wrapContentHeight())
                    }
                    Row(Modifier.weight(1f).fillMaxHeight().clickable { phone.panelFolded = if (folded) phone.panelFolded - group.id else phone.panelFolded + group.id }
                        .semantics { contentDescription = "${if (folded) "Show" else "Hide"} ${group.label}"; if (group.type == null) heading() }
                        .padding(end = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.ExpandMore, null, Modifier.size(12.dp).rotate(if (folded) 180f else 0f), tint = c.label)
                        Spacer(Modifier.weight(1f))
                        if (folded && group.needs > 0) Box(Modifier.padding(end = 4.dp).size(6.dp).background(c.needs, CircleShape))
                        if (group.count > 0) T("${group.count}", Tokens.textSm, c.label)
                    }
                }
            }
            if (!folded) items(WorkList.shown(group, false).first, key = { group.id + it.id }) { item ->
                Row(Modifier.fillMaxWidth().height(40.dp).clickable { open(Route.Task(item.id)) }.padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                    Box(Modifier.width(16.dp), contentAlignment = Alignment.Center) { AgentMark(item.job.agent, 13.dp, c.ink.copy(alpha = 0.7f)) }
                    FadeText(item.job.heading, Tokens.textBase, if (item.status == WorkStatus.Done) c.doneTitle else c.item, modifier = Modifier.weight(1f))
                    WorkMarkView(item.mark)
                }
            }
        }
        item {
            Column(Modifier.padding(top = 16.dp, bottom = 24.dp)) {
                PanelLink("Inbox", phone.loose.size.takeIf { it > 0 }?.toString(), c.needsInk) { open(Route.Inbox) }
                PanelLink("Every task", null, c.label) { open(Route.All) }
                PanelLink("Archived", phone.archived.size.takeIf { it > 0 }?.toString(), c.label) { open(Route.Archived) }
            }
        }
    }
}

@Composable
private fun PanelLink(title: String, count: String?, countColor: androidx.compose.ui.graphics.Color, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(40.dp).clickable(onClick = onClick).padding(horizontal = 12.dp), verticalAlignment = Alignment.CenterVertically) {
        T(title, Tokens.textBase, Tokens.item, modifier = Modifier.weight(1f))
        if (count != null) T(count, Tokens.textBase, countColor)
    }
}
