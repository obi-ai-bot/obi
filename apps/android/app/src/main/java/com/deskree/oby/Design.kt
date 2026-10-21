package com.deskree.oby

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.CompositingStrategy
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import java.time.Instant

/** Sangam's design tokens (design/app tokens.css, apps/shared/Tokens.swift), light and dark as the iPhone has them. */
data class ObyColors(
    val bg: Color, val ink: Color, val text: Color, val muted: Color, val label: Color, val item: Color, val line: Color,
    val lineStrong: Color, val divider: Color, val edge: Color, val hover: Color, val active: Color, val chip: Color, val chipHover: Color,
    val pill: Color, val bubble: Color, val danger: Color, val unread: Color, val needs: Color, val full: Color, val over: Color,
    val done: Color, val surface: Color, val surfaceEdge: Color, val field: Color, val fieldEdgeOn: Color, val railIcon: Color,
    val openTitle: Color, val doneTitle: Color, val working: Color, val check: Color, val needsInk: Color, val onInk: Color,
    val codeBg: Color, val cardFill: Color, val track: Color, val meter: Color, val obyEdge: Color, val stageDone: Color,
    val link: Color, val code: Color, val dark: Boolean,
)

private fun hex(v: Long) = Color(0xFF000000 or v)
private fun white(a: Float) = Color.White.copy(alpha = a)
private fun black(a: Float) = Color.Black.copy(alpha = a)

val DarkColors = ObyColors(
    bg = hex(0x0B0B0B), ink = hex(0xECECEC), text = hex(0xA3A3A8), muted = hex(0x6E6E74), label = white(0.4f), item = white(0.8f),
    line = white(0.10f), lineStrong = white(0.15f), divider = white(0.05f), edge = white(0.08f), hover = white(0.06f), active = white(0.10f),
    chip = hex(0x161617), chipHover = hex(0x1F1F21), pill = white(0.08f), bubble = white(0.12f), danger = hex(0xF07167), unread = hex(0x0A84FF),
    needs = hex(0xFF9F0A), full = hex(0xFFD60A), over = hex(0xFF453A), done = hex(0x30D158), surface = hex(0x181817), surfaceEdge = white(0.08f),
    field = white(0.02f), fieldEdgeOn = white(0.2f), railIcon = white(0.5f), openTitle = white(0.9f), doneTitle = white(0.4f),
    working = white(0.75f), check = white(0.4f), needsInk = hex(0xFF9F0A), onInk = hex(0x111111), codeBg = black(0.3f), cardFill = white(0.06f),
    track = white(0.14f), meter = white(0.08f), obyEdge = Color.Transparent, stageDone = white(0.55f), link = hex(0x64A8FF), code = hex(0xFF8A70),
    dark = true,
)

val LightColors = ObyColors(
    bg = hex(0xF4F4F2), ink = hex(0x161617), text = hex(0x4A4A4F), muted = hex(0x6A6A70), label = black(0.5f), item = black(0.82f),
    line = black(0.10f), lineStrong = black(0.16f), divider = black(0.06f), edge = black(0.08f), hover = black(0.05f), active = black(0.08f),
    chip = hex(0xFFFFFF), chipHover = hex(0xEBEBE9), pill = black(0.06f), bubble = black(0.07f), danger = hex(0xD23F34), unread = hex(0x007AFF),
    needs = hex(0xFF9500), full = hex(0xC99A00), over = hex(0xFF3B30), done = hex(0x28A745), surface = hex(0xFFFFFF), surfaceEdge = black(0.08f),
    field = black(0.02f), fieldEdgeOn = black(0.22f), railIcon = black(0.5f), openTitle = black(0.88f), doneTitle = black(0.4f),
    working = black(0.6f), check = black(0.38f), needsInk = hex(0xB35900), onInk = hex(0xF4F4F2), codeBg = black(0.05f), cardFill = hex(0xFFFFFF),
    track = black(0.12f), meter = black(0.07f), obyEdge = black(0.16f), stageDone = black(0.45f), link = hex(0x0A63CC), code = hex(0xB8432A),
    dark = false,
)

val LocalColors = staticCompositionLocalOf { DarkColors }

/** The tokens by name, as the iPhone's views use them. */
object Tokens {
    val c: ObyColors @Composable get() = LocalColors.current
    val bg @Composable get() = c.bg
    val ink @Composable get() = c.ink
    val text @Composable get() = c.text
    val muted @Composable get() = c.muted
    val label @Composable get() = c.label
    val item @Composable get() = c.item
    val line @Composable get() = c.line
    val divider @Composable get() = c.divider
    val pill @Composable get() = c.pill
    val chip @Composable get() = c.chip
    val danger @Composable get() = c.danger
    val needs @Composable get() = c.needs
    val needsInk @Composable get() = c.needsInk
    val link @Composable get() = c.link

    val textSm = 12.sp
    val textMd = 13.sp
    val textBase = 14.sp
    val textLg = 15.sp
    val textTitle = 24.sp
    val gutter = 20.dp
    val sidebar = 290.dp
    val rail = 48.dp
    val column = 540.dp
    val cardRadius = 22.dp
    val askRadius = 18.dp
    val bubbleRadius = 18.dp
    val rowRadius = 6.dp
    val iconRadius = 8.dp

    val avatars = listOf(0x3A5A8CL, 0x7A4A8CL, 0x2F7A6AL, 0x8C5A3AL, 0x8C3A52L, 0x5A6A2FL, 0x3A7A8CL, 0x6A4A3AL)
    fun avatar(name: String): Color {
        var hash = 5381L
        for (ch in name) hash = ((hash * 33) xor ch.code.toLong()) and 0xFFFFFFFFL
        return hex(avatars[(hash % avatars.size).toInt()])
    }
}

@Composable
fun ObyTheme(dark: Boolean, content: @Composable () -> Unit) {
    val colors = if (dark) DarkColors else LightColors
    val scheme = if (dark) darkColorScheme(background = colors.bg, surface = colors.surface, primary = colors.ink, onPrimary = colors.onInk,
                                           onSurface = colors.ink, onBackground = colors.ink, error = colors.danger)
                 else lightColorScheme(background = colors.bg, surface = colors.surface, primary = colors.ink, onPrimary = colors.onInk,
                                       onSurface = colors.ink, onBackground = colors.ink, error = colors.danger)
    CompositionLocalProvider(LocalColors provides colors) { MaterialTheme(colorScheme = scheme, content = content) }
}

/** One line of text in the design's type: system font, its size and weight. */
@Composable
fun T(text: String, size: TextUnit = Tokens.textBase, color: Color = Tokens.text, weight: FontWeight = FontWeight.Normal, modifier: Modifier = Modifier,
      lines: Int = Int.MAX_VALUE, mono: Boolean = false, italic: Boolean = false, lineHeight: TextUnit = TextUnit.Unspecified, center: Boolean = false) {
    Text(text, modifier, color = color, fontSize = size, fontWeight = weight, maxLines = lines, overflow = TextOverflow.Ellipsis,
         fontFamily = if (mono) FontFamily.Monospace else null, fontStyle = if (italic) FontStyle.Italic else null, lineHeight = lineHeight,
         textAlign = if (center) androidx.compose.ui.text.style.TextAlign.Center else null)
}

/** Text too long for its row fades out over its last 24 points instead of ending in dots (`--fade-out`). */
fun Modifier.fadeOut(): Modifier = graphicsLayer { compositingStrategy = CompositingStrategy.Offscreen }.drawWithContent {
    drawContent()
    val fade = 24.dp.toPx()
    drawRect(Brush.horizontalGradient(listOf(Color.Black, Color.Transparent), startX = size.width - fade, endX = size.width),
             topLeft = Offset(size.width - fade, 0f), size = Size(fade, size.height), blendMode = BlendMode.DstIn)
}

@Composable
fun FadeText(text: String, size: TextUnit = Tokens.textBase, color: Color = Tokens.item, weight: FontWeight = FontWeight.Normal, modifier: Modifier = Modifier) {
    // The fade sits at the row's edge, so only text too long for it reaches the fade.
    Text(text, modifier.fillMaxWidth().fadeOut(), color = color, fontSize = size, fontWeight = weight, maxLines = 1, softWrap = false, overflow = TextOverflow.Clip)
}

fun Modifier.press(onClick: () -> Unit, enabled: Boolean = true): Modifier = clickable(enabled = enabled, onClick = onClick)

/** A plain tap with no ripple, as the design's plain buttons. */
@Composable
fun Modifier.tap(enabled: Boolean = true, onClick: () -> Unit): Modifier =
    clickable(remember { MutableInteractionSource() }, indication = null, enabled = enabled, onClick = onClick)

/** A coding tool's mark: the tool's own brand mark, tinted. Gemini keeps a plain asterisk until it has one. */
@Composable
fun AgentMark(agent: String, size: Dp = 14.dp, tint: Color = Tokens.muted) {
    val mark = when (agent) { "claude" -> R.drawable.mark_claude; "codex" -> R.drawable.mark_openai; "cursor" -> R.drawable.mark_cursor; else -> null }
    if (mark != null) {
        Icon(painterResource(mark), null, Modifier.size(size).graphicsLayer { if (agent == "codex") { scaleX = 1.8f; scaleY = 1.8f } }, tint = tint)
    } else {
        T("✳", (size.value).sp, tint)
    }
}

/** A task's one mark at the end of its row (Sangam's StatusDot). */
@Composable
fun WorkMarkView(mark: WorkMark, dot: Dp = 8.dp) {
    Box(Modifier.size(maxOf(12.dp, dot)).semantics { contentDescription = mark.spoken }, contentAlignment = Alignment.Center) {
        when (mark) {
            WorkMark.New -> Box(Modifier.size(dot).background(Tokens.c.unread, CircleShape))
            WorkMark.Needs -> Box(Modifier.size(dot).background(Tokens.needs, CircleShape))
            WorkMark.Working -> {
                val level by rememberInfiniteTransition(label = "working").animateFloat(0.2f, 1f, infiniteRepeatable(tween(800), RepeatMode.Reverse), label = "dot")
                Box(Modifier.size(dot).graphicsLayer { alpha = level }.background(Tokens.c.working, CircleShape))
            }
            WorkMark.Queued -> {}
            WorkMark.Done -> Icon(Icons.Filled.Check, null, Modifier.size(11.dp), tint = Tokens.c.check)
        }
    }
}

/** A line being worked on: a lighter band sweeps across it every 1.6 seconds (Sangam's `sheen`). */
@Composable
fun Sheen(text: String, size: TextUnit = Tokens.textMd, modifier: Modifier = Modifier, lines: Int = 1) {
    val phase by rememberInfiniteTransition(label = "sheen").animateFloat(-0.3f, 1.3f, infiniteRepeatable(tween(1600, easing = LinearEasing)), label = "band")
    val muted = Tokens.muted; val ink = Tokens.ink
    var width by remember { mutableStateOf(1f) }
    Text(text, modifier, maxLines = lines, overflow = TextOverflow.Ellipsis, onTextLayout = { width = it.size.width.toFloat().coerceAtLeast(1f) },
         style = TextStyle(fontSize = size, brush = Brush.horizontalGradient(
             0f to muted, (phase - 0.15f).coerceIn(0f, 1f) to muted, phase.coerceIn(0f, 1f) to ink, (phase + 0.15f).coerceIn(0f, 1f) to muted, 1f to muted,
             startX = 0f, endX = width)))
}

/** Oby's small face (Sangam's ObyFace.tsx): a soft white block, two tall dark eyes, two short ears. */
@Composable
fun ObyMark(size: Dp = 22.dp) {
    val edge = Tokens.c.obyEdge
    Canvas(Modifier.size(size)) {
        val u = this.size.width / 24
        val body = hex(0xF1F1EE); val eye = hex(0x0D0D0E)
        val ears = Path().apply {
            moveTo(5 * u, 6.6f * u); lineTo(7.9f * u, 3.6f * u); lineTo(8.9f * u, 6.6f * u); close()
            moveTo(19 * u, 6.6f * u); lineTo(16.1f * u, 3.6f * u); lineTo(15.1f * u, 6.6f * u); close()
        }
        if (edge != Color.Transparent) {
            drawPath(ears, edge, style = Stroke(1.2f * u + 1.5f))
            drawRoundRect(edge, Offset(1.5f * u, 6 * u), Size(21 * u, 16.5f * u), CornerRadius(5 * u), style = Stroke(1.5f))
        }
        drawPath(ears, body)
        drawPath(ears, body, style = Stroke(1.2f * u, join = androidx.compose.ui.graphics.StrokeJoin.Round))
        drawRoundRect(body, Offset(1.5f * u, 6 * u), Size(21 * u, 16.5f * u), CornerRadius(5 * u))
        for (x in listOf(6f, 14.6f)) drawRoundRect(eye, Offset(x * u, 10.6f * u), Size(2.8f * u, 5 * u), CornerRadius(1.4f * u))
    }
}

/** Oby's face while it works (Sangam's ObyFaceLive.tsx), simplified: the face, then three dots bouncing in a wave. */
@Composable
fun ObyFaceLive(live: Boolean, size: Dp = 22.dp) {
    if (!live) { ObyMark(size); return }
    val t by rememberInfiniteTransition(label = "dots").animateFloat(0f, (2 * Math.PI).toFloat(), infiniteRepeatable(tween(900, easing = LinearEasing)), label = "wave")
    Canvas(Modifier.size(size)) {
        val u = this.size.width / 24
        for (i in -1..1) {
            val hop = 3 * maxOf(0.0, Math.sin(t - (i + 1) * 0.9)).toFloat()
            drawCircle(hex(0xF1F1EE), 2.1f * u, Offset((12 + i * 8.4f) * u, (14.25f - hop) * u))
        }
    }
}

/** Chips in rows, each row centred (or starting at the left), wrapping when the next one doesn't fit. */
@OptIn(ExperimentalLayoutApi::class)
@Composable
fun Flow(spacing: Dp = 8.dp, centred: Boolean = true, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    FlowRow(modifier, horizontalArrangement = if (centred) Arrangement.spacedBy(spacing, Alignment.CenterHorizontally) else Arrangement.spacedBy(spacing),
            verticalArrangement = Arrangement.spacedBy(spacing)) { content() }
}

/** A pill button (Sangam's `.tc-option`): white 8% at rest, ink filled for the main one, red words for a destructive one. */
@Composable
fun PillButton(title: String, primary: Boolean = false, danger: Boolean = false, quiet: Boolean = false, enabled: Boolean = true,
               pending: Boolean = false, onClick: () -> Unit) {
    val c = Tokens.c
    Row(Modifier.clip(RoundedCornerShape(16.dp)).background(if (primary) c.ink else if (quiet) Color.Transparent else c.pill)
        .clickable(enabled = enabled, onClick = onClick).heightIn(min = 32.dp).padding(horizontal = 14.dp, vertical = 6.dp)
        .graphicsLayer { alpha = if (enabled) 1f else 0.5f },
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        if (pending) CircularProgressIndicator(Modifier.size(12.dp), strokeWidth = 1.5.dp, color = if (primary) c.onInk else c.muted)
        T(title, Tokens.textMd, if (primary) c.onInk else if (danger) c.danger else if (quiet) c.muted else c.item,
          if (primary) FontWeight.Medium else FontWeight.Normal, lines = 2)
    }
}

/**
 * A decision's card (Sangam's AskBlock): its kind in orange (red for a failure), the headline, what
 * happened, the command or file in monospace, the plan, then the choices as pills, the recommended
 * one filled first and Deny in red, and Later. A pick shows a spinner on its pill until the runner confirms it.
 */
@Composable
fun AskCard(kind: String, title: String, options: List<CardOption>, onChoose: (CardOption) -> Unit, failed: Boolean = false, source: String? = null,
            happened: String? = null, behindDetails: String? = null, detail: String? = null, plan: String? = null, busy: Boolean = false,
            hint: String? = null, onLater: (() -> Unit)? = null, explains: Boolean = true) {
    val c = Tokens.c
    var picked by remember { mutableStateOf<String?>(null) }
    var showsDetails by remember { mutableStateOf(false) }
    LaunchedEffect(busy) { if (!busy) picked = null }
    Column(Modifier.fillMaxWidth()) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            T(kind, Tokens.textSm, if (failed) c.danger else c.needsInk, FontWeight.Medium)
            if (!source.isNullOrEmpty()) FadeText(source, Tokens.textSm, c.muted)
        }
        Spacer(Modifier.height(4.dp))
        SelectionContainer { T(title, Tokens.textBase, c.ink, FontWeight.Medium, Modifier.semantics { heading() }, lineHeight = 20.sp) }
        if (!happened.isNullOrEmpty()) SelectionContainer { T(happened, Tokens.textMd, c.text, modifier = Modifier.padding(top = 4.dp), lineHeight = 19.sp) }
        if (!behindDetails.isNullOrEmpty()) {
            Row(Modifier.padding(top = 8.dp).tap { showsDetails = !showsDetails }, verticalAlignment = Alignment.CenterVertically) {
                T("Details", Tokens.textSm, c.muted, FontWeight.Medium)
                Icon(Icons.Filled.ChevronRight, null, Modifier.size(12.dp).graphicsLayer { rotationZ = if (showsDetails) 90f else 0f }, tint = c.muted)
            }
            if (showsDetails) SelectionContainer { T(behindDetails, Tokens.textMd, c.text, modifier = Modifier.padding(top = 6.dp), lineHeight = 19.sp) }
        }
        if (!detail.isNullOrEmpty()) CodeBox(detail)
        if (!plan.isNullOrEmpty()) PlanText(plan, Modifier.padding(top = 10.dp))
        Flow(8.dp, centred = false, modifier = Modifier.padding(top = 14.dp)) {
            options.forEachIndexed { i, option ->
                PillButton(option.label, primary = i == 0 && option.recommended && option.safeOnReturn, danger = option.destructive, enabled = !busy,
                           pending = busy && picked == option.answer) {
                    if (!busy) { picked = option.answer; onChoose(option) }
                }
            }
            if (onLater != null) PillButton("Later", quiet = true, enabled = !busy, onClick = onLater)
        }
        // explains = false: no line under the choices, as Sangam's GitHub card
        val explained = if (explains) options.filter { it.detail != null || it.recommended } else emptyList()
        if (explained.isNotEmpty()) Column(Modifier.padding(top = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            for (o in explained) Text(buildAnnotatedString {
                withStyle(SpanStyle(color = c.text)) { append(o.label) }
                if (o.recommended) withStyle(SpanStyle(color = c.needsInk)) { append(" · Recommended") }
                o.detail?.let { withStyle(SpanStyle(color = c.muted)) { append(": $it") } }
            }, fontSize = Tokens.textSm)
        }
        if (hint != null) T(hint, Tokens.textSm, c.muted, modifier = Modifier.padding(top = 10.dp))
    }
}

@Composable
fun CodeBox(text: String, modifier: Modifier = Modifier.padding(top = 10.dp)) {
    SelectionContainer(modifier.fillMaxWidth().background(Tokens.c.codeBg, RoundedCornerShape(10.dp)).padding(horizontal = 12.dp, vertical = 10.dp)) {
        T(text, 12.sp, Tokens.text, mono = true, lineHeight = 18.sp)
    }
}

/** A plan to approve, as its markdown says it, in at most 220 points that scroll. */
@Composable
fun PlanText(plan: String, modifier: Modifier = Modifier) {
    val c = Tokens.c
    Box(modifier.fillMaxWidth().heightIn(max = 220.dp).background(c.codeBg, RoundedCornerShape(10.dp))) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 12.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            for (block in PlanBlock.blocks(plan)) when (block) {
                is PlanBlock.Heading -> Text(styledSaid(block.text, c), fontSize = Tokens.textMd, fontWeight = FontWeight.SemiBold, color = c.ink)
                is PlanBlock.Item -> Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) { T(block.marker, Tokens.textMd, c.muted); Text(styledSaid(block.text, c), fontSize = Tokens.textMd, color = c.text) }
                is PlanBlock.Code -> T(block.text, 12.sp, c.text, mono = true, modifier = Modifier.fillMaxWidth().background(c.codeBg, RoundedCornerShape(8.dp)).padding(8.dp))
                is PlanBlock.Text -> Text(styledSaid(block.text, c), fontSize = Tokens.textMd, color = c.text)
            }
        }
    }
}

/**
 * Inline markdown as Oby writes it (bold, italics, links, `code`), then what the message box
 * recognises set apart on top: links and references in blue, paths and code in coral monospace.
 * `links` false: nothing in it opens (what an agent writes never opens anything).
 */
fun styledSaid(text: String, c: ObyColors, links: Boolean = true): AnnotatedString {
    val plain = StringBuilder()
    data class Span(val start: Int, val end: Int, val style: SpanStyle, val url: String? = null)
    val spans = mutableListOf<Span>()
    val coral = SpanStyle(color = c.code, fontFamily = FontFamily.Monospace, background = c.pill)
    var i = 0
    val inline = Regex("\\*\\*(.+?)\\*\\*|`([^`\\n]+)`|\\[([^\\]]+)]\\((https?://[^)\\s]+)\\)|(?<![\\w*])\\*([^*\\n]+)\\*(?!\\w)")
    for (m in inline.findAll(text)) {
        plain.append(text, i, m.range.first)
        val start = plain.length
        when {
            m.groups[1] != null -> { plain.append(m.groupValues[1]); spans += Span(start, plain.length, SpanStyle(fontWeight = FontWeight.SemiBold)) }
            m.groups[2] != null -> { plain.append(m.groupValues[2]); spans += Span(start, plain.length, coral) }
            m.groups[3] != null -> { plain.append(m.groupValues[3]); spans += Span(start, plain.length, SpanStyle(color = c.link), m.groupValues[4]) }
            m.groups[5] != null -> { plain.append(m.groupValues[5]); spans += Span(start, plain.length, SpanStyle(fontStyle = FontStyle.Italic)) }
        }
        i = m.range.last + 1
    }
    plain.append(text.substring(i))
    val s = plain.toString()
    val taken = spans.filter { it.url != null || it.style == coral }
    for (match in SaidTokens.matches(s)) {
        val start = match.range.first; val end = match.range.last + 1
        if (taken.any { start < it.end && end > it.start }) continue
        spans += when (match.kind) {
            SaidTokens.Kind.Url -> Span(start, end, SpanStyle(color = c.link), s.substring(start, end))
            SaidTokens.Kind.Ref -> Span(start, end, SpanStyle(color = c.link))
            else -> Span(start, end, coral)
        }
    }
    return buildAnnotatedString {
        append(s)
        for (span in spans) {
            addStyle(span.style, span.start, span.end)
            if (links && span.url != null) addLink(LinkAnnotation.Url(span.url), span.start, span.end)
        }
    }
}

/** What Oby (or you) said: paragraphs a blank line apart, lines starting "- " as a list, tokens set apart. */
@Composable
fun SaidText(text: String, color: Color = Tokens.item, plain: Boolean = false, fading: List<Double> = emptyList(), links: Boolean = true) {
    val c = Tokens.c
    val blocks = if (plain) listOf(listOf(text)) else text.split("\n\n").map { it.trim('\n') }.filter { it.isNotEmpty() }.map { it.split("\n") }
    SelectionContainer {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            blocks.forEachIndexed { b, block ->
                val last = b == blocks.lastIndex
                if (!plain && block.all { it.startsWith("- ") }) {
                    Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        block.forEachIndexed { l, line ->
                            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                T("•", Tokens.textBase, c.muted)
                                Text(faded(styledSaid(line.drop(2), c, links), last && l == block.lastIndex, fading, color), fontSize = Tokens.textBase, color = color, lineHeight = 20.sp)
                            }
                        }
                    }
                } else {
                    Text(faded(styledSaid(block.joinToString("\n"), c, links), last, fading, color), fontSize = Tokens.textBase, color = color, lineHeight = 20.sp)
                }
            }
        }
    }
}

/** The words at the end still coming in, as faint as they are in. */
private fun faded(text: AnnotatedString, last: Boolean, fading: List<Double>, color: Color): AnnotatedString {
    if (!last || fading.isEmpty()) return text
    val s = text.text
    var end = s.length
    val builder = AnnotatedString.Builder(text)
    for (opacity in fading.reversed()) {
        while (end > 0 && s[end - 1].isWhitespace()) end -= 1
        var start = end
        while (start > 0 && !s[start - 1].isWhitespace()) start -= 1
        if (start >= end) break
        builder.addStyle(SpanStyle(color = color.copy(alpha = color.alpha * opacity.toFloat())), start, end)
        end = start
    }
    return builder.toAnnotatedString()
}

/** Oby's words coming in a word at a time from `since` (Sangam's stream.ts). */
@Composable
fun ArrivingSaid(text: String, since: Instant?, color: Color = Tokens.item) {
    if (since == null) { SaidText(text, color); return }
    var now by remember { mutableStateOf(Instant.now()) }
    val elapsed = Format.seconds(since, now)
    val duration = WordReveal.duration(text)
    if (elapsed >= duration) { SaidText(text, color); return }
    LaunchedEffect(text, since) {
        while (Format.seconds(since, Instant.now()) < WordReveal.duration(text)) { delay(33); now = Instant.now() }
        now = Instant.now()
    }
    val (shown, fading) = WordReveal.shown(text, elapsed = elapsed)
    Box(Modifier.semantics { contentDescription = text }) { SaidText(shown, color, fading = fading) }
}

/** Underlined tabs (Sangam's `.line-tabs`): the names with their counts, the open one in ink with a line under it. */
@Composable
fun LineTabs(tab: WorkTab, counts: Map<WorkTab, Int>, onPick: (WorkTab) -> Unit) {
    val c = Tokens.c
    Box(Modifier.fillMaxWidth()) {
        Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(1.dp).background(c.line))
        Row(horizontalArrangement = Arrangement.spacedBy(24.dp)) {
            for (each in WorkTab.entries.filter { it != WorkTab.Todo || counts[it] != null }) {
                Box(Modifier.height(36.dp).width(androidx.compose.foundation.layout.IntrinsicSize.Max).tap { onPick(each) }, contentAlignment = Alignment.Center) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                        T(each.label, Tokens.textBase, if (tab == each) c.ink else c.muted)
                        T("${counts[each] ?: 0}", Tokens.textSm, c.muted)
                    }
                    if (tab == each) Box(Modifier.align(Alignment.BottomStart).fillMaxWidth().height(2.dp).background(c.ink, RoundedCornerShape(1.dp)))
                }
            }
        }
    }
}

/** One part of the task's card (Sangam's `Section`): its name small at the top, a note or a link at its right, a line above it. */
@Composable
fun PageSection(title: String, aside: String? = null, first: Boolean = false, accessory: @Composable () -> Unit = {}, content: @Composable () -> Unit) {
    val c = Tokens.c
    Column(Modifier.fillMaxWidth()) {
        if (!first) Box(Modifier.fillMaxWidth().height(1.dp).background(c.divider))
        Column(Modifier.padding(top = 16.dp, bottom = 18.dp)) {
            Row(Modifier.fillMaxWidth().padding(bottom = 16.dp), verticalAlignment = Alignment.CenterVertically) {
                T(title, Tokens.textSm, c.label, FontWeight.Medium, Modifier.semantics { heading() })
                Spacer(Modifier.weight(1f))
                if (aside != null) T(aside, Tokens.textSm, c.muted)
                accessory()
            }
            content()
        }
    }
}

@Composable
fun SectionLink(title: String, onClick: () -> Unit) {
    Row(Modifier.heightIn(min = 44.dp).tap(onClick = onClick), verticalAlignment = Alignment.CenterVertically) {
        T(title, Tokens.textSm, Tokens.text)
        Icon(Icons.Filled.ChevronRight, null, Modifier.size(12.dp), tint = Tokens.text)
    }
}

@Composable
fun BasisLine(text: String) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(Icons.Outlined.Info, null, Modifier.size(12.dp).padding(top = 1.dp), tint = Tokens.muted)
        T(text, Tokens.textSm, Tokens.muted)
    }
}

/** Your bubble hugs its words, at most 80% of the column, at its right. */
@Composable
fun Bubble(maxWidth: Dp, content: @Composable () -> Unit) {
    Box(Modifier.widthIn(max = maxWidth * 0.8f).background(Tokens.c.bubble, RoundedCornerShape(Tokens.bubbleRadius)).padding(horizontal = 14.dp, vertical = 9.dp)) { content() }
}

// MARK: Settings (Sangam's `.set-*`, apps/shared/SettingsComponents.swift)

/** A titled group of rows on a card, a note under it; what went wrong shows under the card in red. */
@Composable
fun SetGroup(title: String? = null, footer: String? = null, problem: String? = null, rows: List<@Composable () -> Unit>) {
    val c = Tokens.c
    Column(Modifier.fillMaxWidth().padding(bottom = 28.dp)) {
        if (title != null) T(title, Tokens.textMd, c.item, FontWeight.Medium, Modifier.padding(start = 16.dp, end = 16.dp, bottom = 8.dp).semantics { heading() })
        Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(c.surface).border(1.dp, c.surfaceEdge, RoundedCornerShape(16.dp))) {
            rows.forEachIndexed { i, row ->
                if (i > 0) Box(Modifier.fillMaxWidth().height(1.dp).background(c.divider))
                row()
            }
        }
        if (problem != null) SetAbout(problem, c.danger, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp))
        if (footer != null) SetAbout(footer, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp))
    }
}

/** One setting: its name, and a line on it, on the left; its control on the right. At least 56 tall. */
@Composable
fun SetRow(title: String, about: String? = null, quiet: Boolean = false, onClick: (() -> Unit)? = null, label: (@Composable () -> Unit)? = null,
           control: @Composable () -> Unit = {}) {
    val c = Tokens.c
    Row(Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).heightIn(min = 56.dp)
        .padding(horizontal = 16.dp, vertical = 12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            if (label != null) label() else T(title, Tokens.textBase, if (quiet) c.muted else c.ink)
            if (!about.isNullOrEmpty()) SetAbout(about)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) { control() }
    }
}

@Composable
fun SetAbout(text: String, color: Color = Tokens.muted, modifier: Modifier = Modifier) {
    SelectionContainer(modifier) { T(text, Tokens.textSm, color, lineHeight = 17.sp) }
}

@Composable
fun SetValue(text: String, connected: Boolean = false) {
    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        if (connected) Box(Modifier.size(6.dp).background(Tokens.c.done, CircleShape))
        T(text, Tokens.textBase, Tokens.text)
    }
}

@Composable
fun SetCode(text: String) {
    T(text, Tokens.textMd, Tokens.c.code, mono = true, modifier = Modifier.background(Tokens.pill, RoundedCornerShape(4.dp)).padding(horizontal = 3.dp, vertical = 1.dp))
}

/** The on/off switch (`.set-switch`): 32 × 18, never the system's green toggle. */
@Composable
fun SetSwitch(on: Boolean, description: String, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    val c = Tokens.c
    Box(Modifier.size(width = 48.dp, height = 44.dp).tap(enabled) { onChange(!on) }.semantics { contentDescription = description },
        contentAlignment = Alignment.Center) {
        Box(Modifier.size(width = 32.dp, height = 18.dp).background(if (on) c.ink else c.track, CircleShape).graphicsLayer { alpha = if (enabled) 1f else 0.3f }) {
            Box(Modifier.padding(start = if (on) 16.dp else 2.dp, top = 2.dp).size(14.dp).background(if (on) c.bg else c.text, CircleShape))
        }
    }
}

/** A Settings button (`.set-button`): 32 tall, 8 round; red words for one that takes something away. */
@Composable
fun SetButton(title: String, destructive: Boolean = false, enabled: Boolean = true, onClick: () -> Unit) {
    val c = Tokens.c
    Box(Modifier.heightIn(min = 32.dp).clip(RoundedCornerShape(Tokens.iconRadius)).background(c.chipHover).border(1.dp, c.line, RoundedCornerShape(Tokens.iconRadius))
        .clickable(enabled = enabled, onClick = onClick).padding(horizontal = 14.dp).graphicsLayer { alpha = if (enabled) 1f else 0.3f },
        contentAlignment = Alignment.Center) {
        T(title, Tokens.textBase, if (destructive) c.danger else c.ink, lines = 1)
    }
}

/** A pop-up menu (`.set-select`): the chosen option's name and a small chevron in a field's frame. */
@Composable
fun <V> SetSelect(title: String, selection: V, options: List<Pair<V, String>>, onSelect: (V) -> Unit) {
    val c = Tokens.c
    var open by remember { mutableStateOf(false) }
    Box {
        Row(Modifier.height(32.dp).clip(RoundedCornerShape(Tokens.iconRadius)).background(c.field).border(1.dp, c.line, RoundedCornerShape(Tokens.iconRadius))
            .clickable { open = true }.padding(start = 14.dp, end = 10.dp).semantics { contentDescription = title },
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            T(options.firstOrNull { it.first == selection }?.second ?: (selection?.toString() ?: "—"), Tokens.textBase, c.ink, lines = 1,
              modifier = Modifier.widthIn(max = 160.dp))
            Icon(Icons.Filled.ExpandMore, null, Modifier.size(14.dp), tint = c.muted)
        }
        DropdownMenu(open, { open = false }, containerColor = c.surface) {
            for ((value, name) in options) DropdownMenuItem(
                text = { T(name, Tokens.textBase, c.ink) }, onClick = { open = false; onSelect(value) },
                trailingIcon = { if (value == selection) Icon(Icons.Filled.Check, null, tint = c.ink) })
        }
    }
}

/** A segmented choice (`.set-segmented`). */
@Composable
fun <V> SetSegmented(selection: V, options: List<Pair<V, String>>, onSelect: (V) -> Unit) {
    val c = Tokens.c
    Row(Modifier.clip(RoundedCornerShape(Tokens.iconRadius)).background(c.chip).border(1.dp, c.line, RoundedCornerShape(Tokens.iconRadius)).padding(3.dp)) {
        for ((value, name) in options) {
            val on = value == selection
            Box(Modifier.height(30.dp).clip(RoundedCornerShape(Tokens.rowRadius)).background(if (on) c.bubble else Color.Transparent)
                .clickable { onSelect(value) }.padding(horizontal = 12.dp), contentAlignment = Alignment.Center) {
                T(name, Tokens.textMd, if (on) c.ink else c.text)
            }
        }
    }
}

/** A text field (`.set-field`): a field's frame, the prompt muted. */
@Composable
fun SetField(text: String, prompt: String, width: Dp = 220.dp, onChange: (String) -> Unit, keyboard: androidx.compose.foundation.text.KeyboardOptions = androidx.compose.foundation.text.KeyboardOptions.Default,
             onDone: () -> Unit = {}) {
    val c = Tokens.c
    BasicTextField(text, onChange, Modifier.width(width).height(36.dp).clip(RoundedCornerShape(Tokens.iconRadius)).background(c.field)
        .border(1.dp, c.line, RoundedCornerShape(Tokens.iconRadius)).padding(horizontal = 12.dp),
        textStyle = TextStyle(color = c.ink, fontSize = Tokens.textBase), singleLine = true, cursorBrush = SolidColor(c.ink),
        keyboardOptions = keyboard, keyboardActions = androidx.compose.foundation.text.KeyboardActions(onDone = { onDone() }, onGo = { onDone() }),
        decorationBox = { inner -> Box(contentAlignment = Alignment.CenterStart) { if (text.isEmpty()) T(prompt, Tokens.textBase, c.muted); inner() } })
}

/** A usage meter (`.set-meter`): a 4-point bar, `full` past 80% and `over` past 90%. */
@Composable
fun SetMeter(used: Double, modifier: Modifier = Modifier) {
    val c = Tokens.c
    val fill = if (used > 90) c.over else if (used > 80) c.full else c.text
    Box(modifier.widthIn(max = 280.dp).fillMaxWidth().height(4.dp).clip(CircleShape).background(c.meter)) {
        Box(Modifier.fillMaxWidth((used.coerceIn(0.0, 100.0) / 100).toFloat()).height(4.dp).background(fill, CircleShape))
    }
}

/** A link a person tapped: only https GitHub pages and what Oby itself made open (callers check). */
@Composable
fun rememberOpener(): (String) -> Unit {
    val uri = LocalUriHandler.current
    return { url -> runCatching { uri.openUri(url) } }
}

