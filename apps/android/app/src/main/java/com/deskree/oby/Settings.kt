package com.deskree.oby

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.AlertDialog
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
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/**
 * Settings, opened over Home from your picture (Sangam's SettingsView.tsx, apps/ios/app/SettingsScreen.swift):
 * Your Mac, Accounts, Connectors, Models, Permissions, Routines, Notifications, Voice, Appearance, About,
 * then the publishing key. Signing in happens on the Mac, where the tools run.
 */
@Composable
fun SettingsScreen() {
    val phone = LocalPhone.current
    val activity = LocalActivity.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    val (appearance, setAppearance) = LocalAppearance.current
    var options by remember { mutableStateOf<ModelOptions?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var stopping by remember { mutableStateOf(false) }
    LaunchedEffect(phone.base) { options = try { phone.runner.modelOptions() } catch (e: Exception) { problem = e.message; null } }

    Page("") {
        Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Tokens.gutter).padding(top = 8.dp, bottom = 32.dp)) {
            T("Settings", 28.sp, c.ink, FontWeight.SemiBold, Modifier.padding(bottom = 16.dp).semantics { heading() })

            // Your Mac: its name, how it's reached, a green dot while connected; a tap opens pairing.
            val link = phone.link
            SetGroup("Your Mac", rows = listOf {
                SetRow(link?.name ?: "No Mac paired yet", about = if (link == null) "Pair this phone with Oby on your Mac." else phone.route?.label,
                       onClick = { phone.push(Route.Connect) }) {
                    if (link != null) SetValue(phone.notice?.title ?: if (phone.connection == Connection.Live) "Connected" else "Connecting…", phone.connection == Connection.Live)
                    Icon(Icons.Filled.ChevronRight, null, tint = c.muted)
                }
            })

            val now = rememberNow(60)
            SetGroup("Accounts", footer = "Each tool signs in on your Mac, with its own login.", rows = listOf {
                SetRow(Usage.mostRoom(phone.accounts.map { it.usage }, now), quiet = phone.accounts.isEmpty())
            })
            for (agent in Usage.agents(phone.accounts.map { it.agent })) {
                SetGroup(Usage.tool(agent), rows = phone.accounts.filter { it.agent == agent }.map { account -> { AccountRow(account) } })
            }

            // Tetrix, which obid on the Mac holds once for every agent: its sign-in and its login stay on the Mac.
            val tetrix = phone.accounts.any { it.tetrix == true }
            SetGroup("Connectors", footer = if (tetrix) null else "Connect Tetrix on your Mac, in Settings › Connectors: one sign-in, for every agent. Its login stays there, never on this phone.",
                     rows = listOf { SetRow("Tetrix", about = "Project knowledge and blast radius") { SetValue(if (tetrix) "Connected" else "Connect on your Mac", tetrix) } })

            Models(options, phone.models) { scope.launch { problem = try { phone.setModels(it); null } catch (e: Exception) { e.message } } }
            Permissions()
            Routines()
            Notifications()

            val speech = Store.prefs(activity)
            var language by remember { mutableStateOf(speech.getString(VoiceSettings.LANGUAGE, "system") ?: "system") }
            SetGroup("Voice", rows = listOf(
                { SetRow("Speak replies to spoken requests") { SetSwitch(phone.speakReplies, "Speak replies to spoken requests") { phone.setSpeaks(it) } } },
                { SetRow("Speech language") {
                    SetSelect("Speech language", language, listOf("system" to VoiceSettings.SYSTEM_NAME) + VoiceSettings.languages) {
                        language = it; speech.edit().putString(VoiceSettings.LANGUAGE, it).apply()
                    }
                } },
            ))
            SetGroup("Appearance", rows = listOf {
                SetRow("Appearance") { SetSegmented(appearance, listOf("system" to "System", "light" to "Light", "dark" to "Dark"), setAppearance) }
            })
            if (phone.active.isNotEmpty()) SetGroup(footer = "Stops every task on your Mac, as ⌃⌥⌘. does there.", rows = listOf {
                SetRow("Stop every task", about = "${phone.active.size} running") { SetButton("Stop", destructive = true) { stopping = true } }
            })
            SetGroup("About", rows = listOf(
                { SetRow("Version") { SetValue("${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE})") } },
                { SetRow("Mac") { SetValue(phone.host.ifEmpty { "Not reached yet" }) } },
            ))
            SetGroup("Publishing key", problem = problem,
                     footer = "Oby opens a pull request by itself once a job's check passes and the secret scan is clean. Publishing by hand, when that failed, needs your fingerprint or face on this phone.",
                     rows = listOf { SetRow("This phone's key") {
                         SetValue(if (DeviceKey.isAvailable(activity)) (if (phone.deviceID == null) "Not registered yet" else "Registered, biometric") else "Set up a fingerprint or face unlock")
                     } })
        }
    }
    if (stopping) AlertDialog(onDismissRequest = { stopping = false }, containerColor = c.surface,
        title = { T("Stop ${if (phone.active.size == 1) "the running task" else "all ${phone.active.size} running tasks"}?", 17.sp, c.ink, FontWeight.SemiBold) },
        text = { T("Each ends where it is. What they changed stays on their branches.", Tokens.textBase, c.text) },
        confirmButton = { TextButton({ stopping = false; scope.launch { problem = try { phone.stopAll(); null } catch (e: Exception) { e.message } } }) { T("Stop every task", Tokens.textBase, c.danger) } },
        dismissButton = { TextButton({ stopping = false }) { T("Cancel", Tokens.textBase, c.muted) } })
}

/** One account on the Mac: its name, when its week resets, the week's bar, the 5-hour window past 80%, its reserve, and Tetrix. */
@Composable
private fun AccountRow(account: Account) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    val now = rememberNow(60)
    var problem by remember { mutableStateOf<String?>(null) }
    val usage = account.usage
    SetRow(account.name, label = {
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            Box(Modifier.width(16.dp).padding(top = 2.dp)) { AgentMark(account.agent, 14.dp) }
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                T(account.name, Tokens.textBase, c.ink)
                SetAbout(if (account.signedIn) Usage.about(usage, now) else "Signed out: sign in on your Mac")
                Usage.week(usage, now)?.let { SetMeter(it * 100, Modifier.padding(top = 4.dp)) }
                Usage.fiveHourLine(usage, now)?.let { SetAbout(it, if ((usage.fiveHour ?: 0.0) > 0.9) c.over else c.full) }
                if (usage.reserved(now)) SetAbout(Usage.RESERVED_TEXT, c.needsInk)
                if (usage.signedIn && usage.inReserve(now)) {
                    Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        T(Usage.LIFT_TEXT, Tokens.textBase, c.ink, modifier = Modifier.weight(1f))
                        SetSwitch(usage.liftedUntil(now) != null, Usage.LIFT_TEXT) { on ->
                            scope.launch { problem = try { phone.runner.liftReserve(account.id, on); null } catch (e: Exception) { e.message } }
                        }
                    }
                    SetAbout(Usage.liftNote(usage))
                    problem?.let { SetAbout(it, c.danger) }
                }
                if (account.signedIn) SetAbout(TetrixJobReport.accountLine(account.tetrix == true, account.tetrixJobs ?: 0, account.tetrixUsed ?: 0, "on your Mac"),
                                               if (account.tetrix == true) c.muted else c.needsInk)
            }
        }
    })
}

/** The model and effort the runner's Claude Code, Codex and Cursor jobs use, saved there as soon as a choice changes. */
@Composable
private fun Models(options: ModelOptions?, models: ModelSettings?, save: (ModelSettings) -> Unit) {
    options ?: return
    var chosen by remember { mutableStateOf<ModelSettings?>(null) }
    val current = chosen ?: models ?: return
    fun change(update: (ModelSettings) -> ModelSettings) { val next = update(current); chosen = next; save(next) }
    fun efforts(list: List<String>) = list.map { it to ModelChoice.effortName(it) }
    val claudeEfforts = options.claude.efforts.orEmpty()
    val claudeComplex = options.claude.complexEfforts ?: claudeEfforts
    val codexEfforts = options.codex.models.firstOrNull { it.id == current.codex.model }?.efforts.orEmpty()
    SetGroup("Claude Code", rows = listOf(
        { SetRow("Model") { SetSelect("Claude Code model", current.claude.model, options.claude.models.map { it.id to it.name }) { v -> change { it.copy(claude = it.claude.copy(model = v)) } } } },
        { SetRow("Effort") { SetSelect("Claude Code effort", current.claude.effort, efforts(claudeEfforts)) { v -> change { it.copy(claude = it.claude.copy(effort = v)) } } } },
        { SetRow("Complex job effort") { SetSelect("Claude Code complex job effort", current.claude.complexEffort ?: current.claude.effort, efforts(claudeComplex)) { v -> change { it.copy(claude = it.claude.copy(complexEffort = v)) } } } },
    ))
    SetGroup("Codex", rows = listOf(
        { SetRow("Model") { SetSelect("Codex model", current.codex.model, options.codex.models.map { it.id to it.name }) { v -> change { it.copy(codex = it.codex.copy(model = v)) } } } },
        { SetRow("Effort") { SetSelect("Codex effort", current.codex.effort, efforts(codexEfforts)) { v -> change { it.copy(codex = it.codex.copy(effort = v)) } } } },
        { SetRow("Complex job effort") { SetSelect("Codex complex job effort", current.codex.complexEffort ?: current.codex.effort, efforts(codexEfforts)) { v -> change { it.copy(codex = it.codex.copy(complexEffort = v)) } } } },
    ))
    options.cursor?.let { cursor ->
        val choices = listOf("auto" to "Auto") + cursor.models.filter { it.id != "auto" }.map { it.id to it.name }
        SetGroup("Cursor", rows = listOf {
            SetRow("Model") { SetSelect("Cursor model", current.cursor?.model ?: "auto", choices) { v -> change { it.copy(cursor = CursorModelChoice(v)) } } }
        })
    }
}

/** Settings › Permissions: the mode new jobs get, and the rules Always allow (or Deny) saved, each removed with its button. */
@Composable
private fun Permissions() {
    val phone = LocalPhone.current
    val scope = rememberCoroutineScope()
    var rules by remember { mutableStateOf<List<RunnerRule>?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(phone.base) {
        rules = try { phone.runner.permissionRules() } catch (e: RunnerError) { if (e.status != 404) problem = e.message; null } catch (e: Exception) { problem = e.message; null }
    }
    val mode = phone.defaultMode
    val rows = mutableListOf<@Composable () -> Unit>()
    if (mode == null && rules == null) rows += { SetRow("This runner doesn't ask before agents act.", quiet = true) }
    else {
        rows += { SetRow("Default mode", about = mode?.help) {
            SetSelect("Default mode", mode, RunnerMode.entries.map { it to it.label }) { m ->
                if (m != null) scope.launch { problem = try { phone.setDefaultMode(m); null } catch (e: Exception) { e.message } }
            }
        } }
        if (rules?.isEmpty() == true) rows += { SetRow("No saved rules", quiet = true) }
        for (rule in rules.orEmpty()) rows += {
            SetRow(rule.rule, about = listOfNotNull(if (rule.decision == "deny") "Denied" else "Allowed", rule.repo).joinToString(" · "), label = { SetCode(rule.rule) }) {
                SetButton("Remove", destructive = true) {
                    scope.launch { problem = try { phone.runner.removeRule(rule.id); rules = rules?.filter { it.id != rule.id }; null } catch (e: Exception) { e.message } }
                }
            }
        }
    }
    SetGroup("Permissions", problem = problem, rows = rows,
             footer = "Ask: the agent asks before it edits or runs anything. Always allow saves a rule, so it doesn’t ask again; remove the rule to be asked again.")
}

/** Settings › Routines (#395): every routine obid runs on a schedule, with a switch that pauses it, Run now, and Delete (asked first). */
@Composable
private fun Routines() {
    val phone = LocalPhone.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var routines by remember { mutableStateOf<List<RunnerRoutine>?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var deleting by remember { mutableStateOf<RunnerRoutine?>(null) }
    suspend fun load() { routines = try { phone.runner.routines() } catch (e: Exception) { problem = e.message; routines } }
    LaunchedEffect(phone.base, phone.routineChanges) { load() }
    fun act(work: suspend () -> Unit) { scope.launch { problem = try { work(); null } catch (e: Exception) { e.message }; load() } }
    val list = routines
    val rows: List<@Composable () -> Unit> = when {
        list == null -> listOf { SetRow("This runner has no routines.", quiet = true) }
        list.isEmpty() -> listOf { SetRow("No routines yet", quiet = true) }
        else -> list.map { routine -> {
            SetRow(routine.name, about = routine.about()) {
                SetButton("Run now") { act { phone.runner.runRoutine(routine.id) } }
                SetButton("Delete", destructive = true) { deleting = routine }
                SetSwitch(routine.enabled, if (routine.enabled) "Pause ${routine.name}" else "Resume ${routine.name}") { on ->
                    routines = routines?.map { if (it.id == routine.id) it.copy(enabled = on) else it }
                    act { phone.runner.setRoutine(routine.id, on) }
                }
            }
        } }
    }
    SetGroup("Routines", problem = problem, rows = rows,
             footer = "Ask Oby for one, like “every weekday at 9, review the open pull requests in obi”: it waits for your OK in the inbox. Each run is a job on Home, under Routines, with the same checks as any job.")
    deleting?.let { routine ->
        AlertDialog(onDismissRequest = { deleting = null }, containerColor = c.surface,
            title = { T("Delete ${routine.name}?", 17.sp, c.ink, FontWeight.SemiBold) },
            text = { T("It won't run again. The jobs it started stay.", Tokens.textBase, c.text) },
            confirmButton = { TextButton({ deleting = null; act { phone.runner.deleteRoutine(routine.id) } }) { T("Delete", Tokens.textBase, c.danger) } },
            dismissButton = { TextButton({ deleting = null }) { T("Cancel", Tokens.textBase, c.muted) } })
    }
}

/** Notifications: whether Oby may alert you when a job needs you, a way to allow it, and the way to the system's settings. */
@Composable
private fun Notifications() {
    val phone = LocalPhone.current
    val activity = LocalActivity.current
    var allowed by remember { mutableStateOf(Notifications.allowed(activity)) }
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    androidx.compose.runtime.DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, e -> if (e == androidx.lifecycle.Lifecycle.Event.ON_RESUME) allowed = Notifications.allowed(activity) }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer) }
    }
    val configured = Notifications.configured(activity)
    val pushes = phone.pushes
    SetGroup("Notifications", rows = listOf(
        { SetRow("Alerts") {
            SetValue(if (allowed) "Allowed" else "Off")
            SetButton(if (allowed) "Open Settings" else "Allow Alerts") { if (allowed) activity.openNotificationSettings() else { Store.prefs(activity).edit().remove("notifications.asked").apply(); activity.askNotifications() } }
        } },
        { SetRow("Push from your Mac", about = when {
            !configured -> "This build has no Firebase project yet, so alerts come only while Oby is open."
            pushes == true -> "Your Mac sends alerts to this phone."
            pushes == false -> "Your Mac's runner doesn't send pushes yet."
            else -> null
        }) { SetValue(if (configured && pushes == true) "On" else "Off") } },
    ), footer = "Oby alerts you when a job needs you: ready to publish, failed or interrupted, a question for you, out of reviews or not merged. An alert opens its job.")
}
