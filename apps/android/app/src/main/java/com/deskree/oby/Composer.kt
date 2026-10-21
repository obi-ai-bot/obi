package com.deskree.oby

import androidx.compose.animation.AnimatedContent
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
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Popup
import androidx.compose.ui.window.PopupProperties

/**
 * The message box (Sangam's Composer.tsx, apps/ios/app/Composer.swift): a 46-point pill with a thin
 * edge, the words growing to five lines, and at its end the mic, which turns into Send ↑ once there's
 * text. Tap the mic and what you say goes into the field as it's heard; tap Stop and the words stay
 * there to edit and send. Nothing is sent but by Send. Before them, the usage gauge.
 */
@Composable
fun Composer(box: String, prompt: String, onSend: (text: String, spoken: Boolean) -> Unit, onStop: (() -> Unit)? = null, enabled: Boolean = true,
             fill: String? = null, onFilled: () -> Unit = {}) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val voice = phone.voice
    var field by remember(box) { mutableStateOf(TextFieldValue(phone.drafts.text(box))) }
    var dictated by remember(box) { mutableStateOf(false) }
    var written by remember(box) { mutableStateOf<String?>(null) }
    var typing by remember { mutableStateOf(false) }
    val focus = remember { FocusRequester() }
    val focusManager = LocalFocusManager.current
    val haptics = LocalHapticFeedback.current
    val dictating = voice.active || voice.finishing
    val sendable = ChatThread.words(field.text) != null

    fun set(text: String) {
        // Typed, sent or filled from elsewhere: the words heard so far stay, later ones don't come.
        if (text != written && dictating) voice.cancel()
        if (text.isEmpty()) dictated = false
        field = TextFieldValue(text, TextRange(text.length))
        phone.drafts.keep(text, box)
    }

    // Edit on a failed message or a plan card: its words come back into the field.
    LaunchedEffect(fill) { if (fill != null) { set(fill); onFilled(); focus.requestFocus() } }
    // Leaving the screen stops listening; the words heard stay.
    DisposableEffect(box) { onDispose { phone.cancelVoice() } }
    LaunchedEffect(voice.listening) { if (voice.listening) haptics.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.TextHandleMove) }

    fun send() {
        if (!sendable || !enabled) return
        onSend(field.text, dictated)
        set("")
        focusManager.clearFocus()
    }

    fun toggleDictation() {
        if (voice.active) { voice.finish(); return }
        focusManager.clearFocus()
        val prefix = field.text
        written = prefix
        phone.dictate { words ->
            if (words.isEmpty() || field.text != written) return@dictate
            val text = Dictation.draft(prefix, words)
            field = TextFieldValue(text, TextRange(text.length))
            written = text
            dictated = true
            phone.drafts.keep(text, box)
        }
    }

    Column(Modifier.fillMaxWidth().background(c.bg).padding(horizontal = Tokens.gutter, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
        if (dictating) T(if (voice.finishing) "Writing down…" else if (voice.listening) "Listening…" else "Getting ready…", Tokens.textSm, c.muted, modifier = Modifier.padding(horizontal = 16.dp))
        voice.problem?.let { T(it, Tokens.textSm, c.danger, modifier = Modifier.padding(horizontal = 16.dp)) }
        Row(Modifier.fillMaxWidth().heightIn(min = 46.dp).border(1.dp, if (typing) c.fieldEdgeOn else c.line, RoundedCornerShape(23.dp)).padding(6.dp),
            verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            BasicTextField(field, { set(it.text); field = it }, Modifier.weight(1f).heightIn(min = 32.dp).padding(horizontal = 10.dp, vertical = 6.dp)
                .focusRequester(focus).onFocusChanged { typing = it.isFocused }.semantics { contentDescription = prompt },
                enabled = enabled, textStyle = TextStyle(color = c.openTitle, fontSize = Tokens.textLg), maxLines = 5, cursorBrush = SolidColor(c.ink),
                decorationBox = { inner -> Box { if (field.text.isEmpty()) T(prompt, Tokens.textLg, c.muted, lines = 1); inner() } })
            if (phone.accounts.isNotEmpty()) UsageGauge()
            Box(Modifier.size(32.dp), contentAlignment = Alignment.Center) {
                AnimatedContent(when { onStop != null && !dictating && !sendable -> 0; dictating || !sendable -> 1; else -> 2 }, label = "end") { slot ->
                    when (slot) {
                        // A filled square on a `hover` circle: ends the turn under way.
                        0 -> Box(Modifier.size(32.dp).background(c.hover, CircleShape).clickable { onStop?.invoke() }.semantics { contentDescription = "Stop" },
                                 contentAlignment = Alignment.Center) { Icon(Icons.Filled.Stop, null, Modifier.size(14.dp), tint = c.ink) }
                        1 -> DictationMic(voice.active, voice.listening, voice.finishing, voice.level, ::toggleDictation)
                        else -> Box(Modifier.size(32.dp).clickable(onClick = ::send).semantics { contentDescription = "Send" }, contentAlignment = Alignment.Center) {
                            Icon(Icons.Filled.ArrowUpward, null, Modifier.size(20.dp), tint = c.ink)
                        }
                    }
                }
            }
        }
    }
}

object Dictation {
    /** What the field holds with `words` dictated after `prefix`: a space between, unless there's one. */
    fun draft(prefix: String, words: String) = if (prefix.isEmpty() || prefix.last().isWhitespace()) prefix + words else "$prefix $words"
}

/** The box's mic: Dictate, or a red Stop with the input's level under it while it listens. */
@Composable
private fun DictationMic(active: Boolean, listening: Boolean, finishing: Boolean, level: Float, toggle: () -> Unit) {
    val c = Tokens.c
    Column(Modifier.size(32.dp).background(if (active) c.active else androidx.compose.ui.graphics.Color.Transparent, CircleShape)
        .clickable(enabled = !finishing, onClick = toggle).semantics { contentDescription = if (active) "Stop dictating" else "Dictate" },
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
        Icon(if (active) Icons.Filled.Stop else Icons.Filled.GraphicEq, null, Modifier.size(if (active) 14.dp else 18.dp), tint = if (active) c.danger else c.muted)
        if (listening) {
            Spacer(Modifier.height(2.dp))
            Box(Modifier.width((6 + level * 14).dp).height(2.dp).background(c.danger.copy(alpha = 0.6f), CircleShape))
        }
    }
}

/** How much the accounts have used this week (Sangam's UsageGauge): a dot past 80% (yellow) or 90% (red); a tap shows each account's week. */
@Composable
private fun UsageGauge() {
    val phone = LocalPhone.current
    val c = Tokens.c
    var open by remember { mutableStateOf(false) }
    val dot = UsageDot.of(phone.accounts.map { Usage.week(it.usage) })
    Box {
        Box(Modifier.size(32.dp).background(if (open) c.active else androidx.compose.ui.graphics.Color.Transparent, CircleShape).clickable { open = !open }
            .semantics { contentDescription = "Usage this week" + if (dot == UsageDot.None) "" else ", an account is nearly full" }, contentAlignment = Alignment.Center) {
            Icon(Icons.Filled.Speed, null, Modifier.size(18.dp), tint = if (open) c.ink else c.muted)
            if (dot != UsageDot.None) Box(Modifier.align(Alignment.TopEnd).offset((-4).dp, 5.dp).size(6.dp).background(if (dot == UsageDot.Over) c.over else c.full, CircleShape))
        }
        if (open) Popup(alignment = Alignment.BottomEnd, offset = androidx.compose.ui.unit.IntOffset(0, -120), onDismissRequest = { open = false },
                        properties = PopupProperties(focusable = true)) {
            Column(Modifier.widthIn(max = 340.dp).background(c.surface, RoundedCornerShape(14.dp)).border(1.dp, c.surfaceEdge, RoundedCornerShape(14.dp))
                .padding(start = 8.dp, end = 8.dp, top = 8.dp, bottom = 16.dp)) {
                Row(Modifier.fillMaxWidth().padding(start = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    T("Usage this week", Tokens.textSm, c.label, modifier = Modifier.weight(1f))
                    Box(Modifier.size(36.dp).clickable { open = false; phone.panel = null; phone.push(Route.Settings) }.semantics { contentDescription = "Manage accounts" },
                        contentAlignment = Alignment.Center) { Icon(Icons.Filled.Settings, null, Modifier.size(16.dp), tint = c.muted) }
                }
                for (account in phone.accounts) {
                    val week = Usage.week(account.usage)
                    val level = UsageDot.of(listOf(week))
                    Row(Modifier.padding(8.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        AgentMark(account.agent, 14.dp)
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                FadeText("${Usage.tool(account.agent)} · ${account.name}", Tokens.textBase, c.ink, modifier = Modifier.weight(1f))
                                account.sevenDayResets?.let { T(Usage.resetText(it), Tokens.textSm, c.muted, lines = 1) }
                                T(week?.let(Usage::percent) ?: "–", Tokens.textBase, if (level == UsageDot.Over) c.over else if (level == UsageDot.High) c.full else c.text)
                            }
                            SetMeter((week ?: 0.0) * 100)
                        }
                    }
                }
            }
        }
    }
}
