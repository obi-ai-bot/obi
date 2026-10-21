package com.deskree.oby

import androidx.compose.ui.text.withStyle
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.animateDpAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInHorizontally
import androidx.compose.animation.slideOutHorizontally
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Person
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

/** The app's one phone and activity, for every screen. */
val LocalPhone = staticCompositionLocalOf<Phone> { error("no phone") }
val LocalActivity = staticCompositionLocalOf<MainActivity> { error("no activity") }

/**
 * Oby on a phone with no tab bar (apps/ios/app/SidePanel.swift's PhoneRoot): Connect first until it
 * pairs, then Home and everything opened over it in one stack, and Sangam's side panel. The panel
 * opens from the left and pushes the view over: the panel button at Home's top left, or a swipe from
 * the screen's left edge on Home; a tap on what it pushed aside, a swipe back, or Back closes it.
 * Back pops the stack, and on Home itself leaves the app.
 */
@Composable
fun PhoneRoot(phone: Phone, activity: MainActivity, appearance: String, setAppearance: (String) -> Unit) {
    CompositionLocalProvider(LocalPhone provides phone, LocalActivity provides activity, LocalAppearance provides (appearance to setAppearance)) {
        Box(Modifier.fillMaxSize().background(Tokens.bg)) {
            if (phone.needsPairing) {
                Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
                    phone.notice?.let { ReachLine(it) }
                    ConnectScreen(first = true)
                }
            } else Panelled(phone)
        }
    }
}

val LocalAppearance = staticCompositionLocalOf<Pair<String, (String) -> Unit>> { "system" to {} }

@Composable
private fun Panelled(phone: Phone) {
    BoxWithConstraints(Modifier.fillMaxSize()) {
        val density = LocalDensity.current
        val width = minOf(Tokens.sidebar + 40.dp, maxWidth - 56.dp)
        val widthPx = with(density) { width.toPx() }
        val open = phone.panel != null
        var drag by remember { mutableFloatStateOf(0f) }
        val rest by animateDpAsState(if (open) width else 0.dp, tween(320), label = "panel")
        val shift = (with(density) { rest.toPx() } + drag).coerceIn(0f, widthPx)

        BackHandler(open) { phone.panel = null }
        BackHandler(!open && phone.homePath.isNotEmpty()) { phone.pop() }

        Box(Modifier.width(width).fillMaxHeight().offset { IntOffset((shift - widthPx).roundToInt(), 0) }
            .then(if (open) Modifier else Modifier.clearAndSetSemantics {})) {
            SidePanel(close = { phone.panel = null })
        }
        Box(Modifier.fillMaxSize().offset { IntOffset(shift.roundToInt(), 0) }
            .pointerInput(open, phone.homePath.isEmpty()) {
                // Home's left edge: a swipe right opens the panel; over a page the edge is Android's own back gesture.
                if (!open && phone.homePath.isNotEmpty()) return@pointerInput
                var fromEdge = false
                detectHorizontalDragGestures(
                    onDragStart = { fromEdge = open || it.x < 32.dp.toPx() },
                    onDragEnd = {
                        if (fromEdge) {
                            if (!open && drag > widthPx / 3) phone.panel = PanelSection.Home
                            if (open && drag < -widthPx / 3) phone.panel = null
                        }
                        drag = 0f
                    },
                    onDragCancel = { drag = 0f },
                ) { _, amount -> if (fromEdge) drag = (drag + amount).coerceIn(if (open) -widthPx else 0f, if (open) 0f else widthPx) }
            }) {
            HomeStack(phone)
            if (shift > 0f) Box(Modifier.fillMaxSize().background(Tokens.bg.copy(alpha = 0.4f * shift / widthPx)).tap { phone.panel = null })
        }
    }
}

/** Home, and the page on top of the stack over it. */
@Composable
private fun HomeStack(phone: Phone) {
    Column(Modifier.fillMaxSize().windowInsetsPadding(WindowInsets.safeDrawing)) {
        phone.notice?.let { ReachLine(it) }
        val top = phone.homePath.lastOrNull()
        AnimatedContent(top to phone.homePath.size, transitionSpec = {
            if (targetState.second >= initialState.second) (slideInHorizontally { it / 3 } + fadeIn(tween(220))) togetherWith fadeOut(tween(120))
            else fadeIn(tween(220)) togetherWith (slideOutHorizontally { it / 3 } + fadeOut(tween(160)))
        }, label = "stack") { (route, _) ->
            when (route) {
                null -> HomeView()
                is Route.Kind -> KindPage(route.kind)
                is Route.Task -> TaskPage(route.id)
                is Route.Conversation -> ConversationPage(route.id, isNew = false)
                Route.NewConversation -> ConversationPage(null, isNew = true)
                Route.All -> AllTasksPage()
                Route.Archived -> ArchivedPage()
                Route.Inbox -> InboxPage()
                Route.Settings -> SettingsScreen()
                Route.Connect -> Page(title = "") { ConnectScreen(first = false) }
            }
        }
    }
}

/** A page over Home: Back, an inline title, what it offers at the top right, then its content. */
@Composable
fun Page(title: String, menu: (@Composable () -> Unit)? = null, content: @Composable () -> Unit) {
    val phone = LocalPhone.current
    Column(Modifier.fillMaxSize().background(Tokens.bg)) {
        Row(Modifier.fillMaxWidth().height(52.dp).padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(48.dp).tap { phone.pop() }.semantics { contentDescription = "Back" }, contentAlignment = Alignment.Center) {
                Icon(Icons.AutoMirrored.Filled.ArrowBack, null, tint = Tokens.ink)
            }
            T(title, 16.sp, Tokens.ink, FontWeight.SemiBold, Modifier.weight(1f), lines = 1, center = true)
            Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) { menu?.invoke() }
        }
        Box(Modifier.weight(1f)) { content() }
    }
}

@Composable
fun MenuButton(description: String, onClick: () -> Unit) {
    Box(Modifier.size(48.dp).tap(onClick = onClick).semantics { contentDescription = description }, contentAlignment = Alignment.Center) {
        Icon(Icons.Filled.MoreVert, null, tint = Tokens.ink)
    }
}

/** The notice as one line where you are: the title in `ink`, why in `muted`, an orange dot ahead. */
@Composable
fun ReachLine(notice: ReachNotice) {
    val c = Tokens.c
    Row(Modifier.fillMaxWidth().background(c.bg).padding(horizontal = Tokens.gutter, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Box(Modifier.padding(top = 5.dp).size(6.dp).background(if (notice == ReachNotice.Removed || notice == ReachNotice.Expired) c.danger else c.needs, CircleShape))
        androidx.compose.material3.Text(androidx.compose.ui.text.buildAnnotatedString {
            withStyle(androidx.compose.ui.text.SpanStyle(color = c.ink)) { append(notice.title) }
            append("  ")
            withStyle(androidx.compose.ui.text.SpanStyle(color = c.muted)) { append(notice.detail) }
        }, fontSize = Tokens.textSm, maxLines = 2)
    }
}

/** Your picture until there's a photo (Sangam's OwnerAvatar): your initial on a colour picked from your name. */
@Composable
fun OwnerPicture(name: String?) {
    if (!name.isNullOrEmpty()) {
        Box(Modifier.size(28.dp).background(Tokens.avatar(name), CircleShape), contentAlignment = Alignment.Center) {
            T(name.take(1), 11.sp, androidx.compose.ui.graphics.Color.White.copy(alpha = 0.92f), FontWeight.SemiBold)
        }
    } else Icon(Icons.Filled.Person, null, Modifier.size(26.dp), tint = Tokens.c.railIcon)
}

@Composable
fun Gap(h: Int) = Spacer(Modifier.height(h.dp))
