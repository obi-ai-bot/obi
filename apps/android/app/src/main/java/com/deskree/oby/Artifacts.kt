package com.deskree.oby

import android.annotation.SuppressLint
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.view.MotionEvent
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.ByteArrayInputStream
import java.io.File

/**
 * How the app loads an artifact's page (docs/conversation-harness.md section 4): from
 * `https://artifact.oby.invalid/<id>/<version>/<path>`, a host no network has, which the WebView's
 * own request handler fetches from obid with the device token, passing obid's Content-Security-Policy
 * on. Nothing else loads; links out are offered only after a real tap.
 */
object ArtifactPage {
    const val HOST = "artifact.oby.invalid"
    const val POLICY = "default-src 'self' data: blob:; script-src 'self' 'unsafe-inline' data: blob:; style-src 'self' 'unsafe-inline' data:; img-src 'self' data: blob:; connect-src 'none'; frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; sandbox allow-scripts"

    fun url(ref: ArtifactRef, path: String) = "https://$HOST/${Uri.encode(ref.id)}/${ref.version}/" + path.split("/").joinToString("/") { Uri.encode(it) }

    /** The file of `ref`'s version that `url` names, or null for anything else (another artifact or version, a way out). */
    fun path(url: Uri, ref: ArtifactRef): String? {
        if (url.scheme != "https" || url.host != HOST) return null
        val parts = url.pathSegments
        if (parts.size < 3 || parts[0] != ref.id || parts[1] != ref.version.toString()) return null
        val file = parts.drop(2)
        if (file.any { it.isEmpty() || it == "." || it == ".." }) return null
        return file.joinToString("/")
    }
}

/** When a link out may be offered: only within a second of a real tap, once per tap, never again after a Cancel. */
class LinkGate {
    private var touched = 0L
    var refused = false
    fun touch() { touched = System.currentTimeMillis() }
    fun offer(): Boolean {
        val now = System.currentTimeMillis()
        if (refused || now - touched !in 0..1000) return false
        touched = 0
        return true
    }
}

@SuppressLint("SetJavaScriptEnabled", "ClickableViewAccessibility")
@Composable
private fun ArtifactWeb(ref: ArtifactRef, path: String, runner: Runner, gate: LinkGate, ask: (String) -> Unit, modifier: Modifier = Modifier) {
    AndroidView({ context ->
        WebView(context).apply {
            setBackgroundColor(android.graphics.Color.TRANSPARENT)
            settings.javaScriptEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            settings.domStorageEnabled = false
            settings.mediaPlaybackRequiresUserGesture = true
            settings.javaScriptCanOpenWindowsAutomatically = false
            settings.setSupportMultipleWindows(false)
            setOnTouchListener { _, event -> if (event.action == MotionEvent.ACTION_DOWN) gate.touch(); false }
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                // No WebRTC: a CSP has no rule for it.
                WebViewCompat.addDocumentStartJavaScript(this, """
                    for (const name of ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCRtpSender', 'RTCRtpReceiver']) {
                      try { Object.defineProperty(window, name, { value: undefined, writable: false, configurable: false }); } catch (e) {}
                    }
                    try { Object.defineProperty(navigator, 'mediaDevices', { value: undefined, configurable: false }); } catch (e) {}
                """.trimIndent(), setOf("https://${ArtifactPage.HOST}"))
            }
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse {
                    val file = ArtifactPage.path(request.url, ref) ?: return WebResourceResponse("text/plain", "utf-8", 404, "Not found", emptyMap(), null)
                    return try {
                        runner.artifactFile(ref, file).use { answer ->
                            val type = answer.header("Content-Type") ?: "application/octet-stream"
                            val headers = mutableMapOf("Content-Security-Policy" to (answer.header("Content-Security-Policy") ?: ArtifactPage.POLICY),
                                                       "Access-Control-Allow-Origin" to "*")
                            listOf("X-Content-Type-Options", "Referrer-Policy").forEach { name -> answer.header(name)?.let { headers[name] = it } }
                            WebResourceResponse(type.substringBefore(';').trim(), "utf-8", answer.code, answer.message.ifEmpty { "OK" }, headers,
                                                ByteArrayInputStream(answer.body.bytes()))
                        }
                    } catch (e: Exception) {
                        WebResourceResponse("text/plain", "utf-8", 502, "Bad gateway", emptyMap(), null)
                    }
                }

                // A page that crashes its renderer takes only its own view down.
                override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail) = true

                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    if (ArtifactPage.path(request.url, ref) != null) return false
                    val url = request.url
                    if ((url.scheme == "http" || url.scheme == "https") && request.hasGesture() && gate.offer()) ask(url.toString())
                    return true
                }
            }
            loadUrl(ArtifactPage.url(ref, path))
        }
    }, modifier, onRelease = { it.destroy() })
}

private sealed interface ArtifactContent {
    data class Page(val path: String) : ArtifactContent
    data class Markdown(val text: String) : ArtifactContent
    data class Picture(val bitmap: Bitmap) : ArtifactContent
    data class Pdf(val pages: List<Bitmap>) : ArtifactContent
    data class Canvas(val frames: List<Frame>) : ArtifactContent
}

private data class Frame(val title: String?, val file: String, val w: Double, val h: Double, val picked: Boolean)

/**
 * An artifact open, full screen over the conversation: close at the left, the title and "Page · made
 * by Oby" in the middle, its version at the right. HTML in its sandboxed web view with scripts on and
 * no network; Markdown in Oby's own type; an image or a PDF natively; a canvas as its frames.
 */
@Composable
fun ArtifactViewer(ref: ArtifactRef, artifact: RunnerArtifact?, agent: String?, close: () -> Unit) {
    val phone = LocalPhone.current
    val c = Tokens.c
    val runner = phone.runner
    var known by remember { mutableStateOf(artifact) }
    var version by remember { mutableStateOf(ref.version) }
    var content by remember { mutableStateOf<ArtifactContent?>(null) }
    var problem by remember { mutableStateOf<String?>(null) }
    var leaving by remember { mutableStateOf<String?>(null) }
    var versions by remember { mutableStateOf(false) }
    val gate = remember { LinkGate() }
    val open = rememberOpener()
    val shown = ArtifactRef(ref.id, version)
    fun ask(url: String) { if (!gate.refused) leaving = url }

    LaunchedEffect(shown) {
        content = null; problem = null
        try {
            var a = known
            if (a?.files(version).isNullOrEmpty()) runner.artifact(ref.id)?.let { a = it }
            known = a
            val found = a ?: run { problem = "Oby doesn't keep this artifact any more."; return@LaunchedEffect }
            val files = found.files(version)
            suspend fun file(path: String): ByteArray = withContext(Dispatchers.IO) {
                runner.artifactFile(shown, path).use { if (!it.isSuccessful) throw RunnerError("The runner answered ${it.code} for $path."); it.body.bytes() }
            }
            content = when (found.kind) {
                "html" -> ArtifactContent.Page(if ("index.html" in files || files.isEmpty()) "index.html" else files[0])
                "canvas" -> {
                    val frames = frames(String(file("canvas.json")))
                    if (frames.isEmpty()) { problem = "The canvas has no frames to show."; null } else ArtifactContent.Canvas(frames)
                }
                else -> {
                    val first = files.firstOrNull() ?: run { problem = "This version has no files."; return@LaunchedEffect }
                    when {
                        found.kind == "markdown" -> ArtifactContent.Markdown(String(file(first)))
                        found.kind == "pdf" -> ArtifactContent.Pdf(file(first).let { bytes -> withContext(Dispatchers.IO) { pdf(bytes) } })
                        found.kind == "image" && !first.lowercase().endsWith(".svg") -> {
                            val bytes = file(first)
                            BitmapFactory.decodeByteArray(bytes, 0, bytes.size)?.let { ArtifactContent.Picture(it) }
                                ?: run { problem = "This image can't be shown."; null }
                        }
                        // An SVG may hold scripts: it's a page, under obid's policy like one.
                        else -> ArtifactContent.Page(first)
                    }
                }
            }
        } catch (e: Exception) { problem = e.message }
    }

    Dialog(close, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Column(Modifier.fillMaxSize().background(c.bg).windowInsetsPadding(WindowInsets.safeDrawing)) {
            Row(Modifier.fillMaxWidth().padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 10.dp), verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.size(32.dp).background(c.pill, CircleShape).clickable(onClick = close).semantics { contentDescription = "Close" }, contentAlignment = Alignment.Center) {
                    Icon(Icons.Filled.Close, null, Modifier.size(16.dp), tint = c.ink)
                }
                Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                    T(known?.title ?: "Artifact", Tokens.textBase, c.ink, FontWeight.SemiBold, lines = 1)
                    T(known?.line(null, agent) ?: "", Tokens.textSm, c.muted, lines = 1)
                }
                Box {
                    val count = known?.versions?.size ?: 0
                    Box(Modifier.height(28.dp).background(c.pill, CircleShape).clickable(enabled = count > 1) { versions = true }.padding(horizontal = 10.dp),
                        contentAlignment = Alignment.Center) { T("v$version", Tokens.textSm, c.text, FontWeight.Medium) }
                    DropdownMenu(versions, { versions = false }, containerColor = c.surface) {
                        for (each in known?.versions?.map { it.version }?.sortedDescending().orEmpty()) DropdownMenuItem({ T("Version $each", Tokens.textBase, c.ink) }, { version = each; versions = false })
                    }
                }
            }
            Box(Modifier.weight(1f).fillMaxWidth()) {
                when (val shownContent = content) {
                    null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        problem?.let { T(it, Tokens.textSm, c.danger) } ?: CircularProgressIndicator(color = c.muted)
                    }
                    is ArtifactContent.Page -> ArtifactWeb(shown, shownContent.path, runner, gate, ::ask, Modifier.fillMaxSize())
                    is ArtifactContent.Markdown -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        for (block in MdBlock.blocks(shownContent.text)) when (block) {
                            is MdBlock.Heading -> T(block.text, if (block.level == 1) 22.sp else 15.sp, c.ink, FontWeight.SemiBold)
                            is MdBlock.Code -> Box(Modifier.fillMaxWidth().background(c.pill, RoundedCornerShape(10.dp)).horizontalScroll(rememberScrollState()).padding(12.dp)) {
                                T(block.text, 13.sp, c.ink, mono = true)
                            }
                            is MdBlock.Text -> SaidText(block.text, c.item, links = false)
                        }
                    }
                    is ArtifactContent.Picture -> Image(shownContent.bitmap.asImageBitmap(), known?.title, Modifier.fillMaxSize().padding(Tokens.gutter), contentScale = ContentScale.Fit)
                    is ArtifactContent.Pdf -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                        for (page in shownContent.pages) Image(page.asImageBitmap(), null, Modifier.fillMaxWidth().aspectRatio(page.width.toFloat() / page.height), contentScale = ContentScale.FillWidth)
                    }
                    is ArtifactContent.Canvas -> Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(Tokens.gutter), verticalArrangement = Arrangement.spacedBy(18.dp)) {
                        for (frame in shownContent.frames) Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            T(frame.title ?: frame.file, 11.sp, c.text, FontWeight.Medium, lines = 1)
                            Box(Modifier.fillMaxWidth().aspectRatio((frame.w / frame.h).toFloat()).background(c.cardFill, RoundedCornerShape(8.dp))
                                .then(if (frame.picked) Modifier.border(2.dp, c.unread, RoundedCornerShape(8.dp)) else Modifier)) {
                                ArtifactWeb(shown, frame.file, runner, gate, ::ask, Modifier.fillMaxSize())
                            }
                        }
                    }
                }
            }
            if (content is ArtifactContent.Page) T("Runs on this phone with no network", Tokens.textSm, c.muted, center = true, modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp))
            Spacer(Modifier.height(4.dp))
        }
    }
    leaving?.let { url ->
        AlertDialog(onDismissRequest = { leaving = null }, containerColor = c.surface,
            title = { T("Open ${Uri.parse(url).host ?: "this link"} in your browser?", 17.sp, c.ink, FontWeight.SemiBold) },
            text = { T(url, Tokens.textSm, c.muted) },
            confirmButton = { TextButton({ leaving = null; open(url) }) { T("Open", Tokens.textBase, c.ink) } },
            dismissButton = { TextButton({ leaving = null; gate.refused = true }) { T("Cancel", Tokens.textBase, c.muted) } })
    }
}

/** The frames `canvas.json` lists (a list, or `{"frames": […]}`), at most 24, each with a size and a file inside the version. */
private fun frames(json: String): List<Frame> {
    val root = runCatching { wire.parseToJsonElement(json) }.getOrNull() ?: return emptyList()
    val list = (root as? kotlinx.serialization.json.JsonArray) ?: ((root as? kotlinx.serialization.json.JsonObject)?.get("frames") as? kotlinx.serialization.json.JsonArray) ?: return emptyList()
    return list.mapNotNull { e ->
        val o = e as? kotlinx.serialization.json.JsonObject ?: return@mapNotNull null
        fun s(k: String) = (o[k] as? kotlinx.serialization.json.JsonPrimitive)?.content
        val file = s("file") ?: return@mapNotNull null
        val w = s("w")?.toDoubleOrNull() ?: return@mapNotNull null
        val h = s("h")?.toDoubleOrNull() ?: return@mapNotNull null
        if (w <= 0 || h <= 0 || file.startsWith("/") || file.split("/").any { it.isEmpty() || it == ".." }) return@mapNotNull null
        Frame(s("title"), file, minOf(w, 4096.0), minOf(h, 4096.0), s("picked") == "true")
    }.take(24)
}

/** A PDF's pages as pictures (PdfRenderer), at most 50. */
private fun pdf(data: ByteArray): List<Bitmap> {
    val file = File.createTempFile("artifact", ".pdf")
    try {
        file.writeBytes(data)
        ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
            PdfRenderer(fd).use { renderer ->
                return (0 until minOf(renderer.pageCount, 50)).map { i ->
                    renderer.openPage(i).use { page ->
                        val scale = 2
                        Bitmap.createBitmap(page.width * scale, page.height * scale, Bitmap.Config.ARGB_8888).also {
                            it.eraseColor(android.graphics.Color.WHITE)
                            page.render(it, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                        }
                    }
                }
            }
        }
    } finally {
        file.delete()
    }
}
