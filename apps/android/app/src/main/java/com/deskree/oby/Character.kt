package com.deskree.oby

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Color
import android.util.Log
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject

/** The page's events come back here, as `{ oby: name, … }` (character/oby.html's `emit`). */
class CharacterBridge(private val received: (String) -> Unit) {
    @JavascriptInterface
    fun post(message: String) {
        runCatching { JSONObject(message).optString("oby") }.getOrNull()?.takeIf { it.isNotEmpty() }?.let(received)
    }
}

/**
 * Sangam's character (apps/shared/Character.swift): `character/oby.html` and three.js, bundled into
 * the app's assets and served from the WebView's own https origin so its ES modules load. One page
 * for the app; it draws only while Home's stage shows.
 */
@SuppressLint("SetJavaScriptEnabled")
class ObyCharacter(context: Context) {
    var ready by mutableStateOf(false); private set
    private var loaded = false
    private var paused = false
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    val view: WebView = WebView(context).apply {
        layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
        setBackgroundColor(Color.TRANSPARENT)
        isVerticalScrollBarEnabled = false
        isHorizontalScrollBarEnabled = false
        // Oby takes no touch: the stage under it does.
        isClickable = false
        isFocusable = false
        setOnTouchListener { _, _ -> true }
        importantForAccessibility = android.view.View.IMPORTANT_FOR_ACCESSIBILITY_NO
        settings.javaScriptEnabled = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.mediaPlaybackRequiresUserGesture = true
        val assets = WebViewAssetLoader.Builder().addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context)).build()
        webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                // Only the bundled character's files, nothing from anywhere else.
                if (request.url.host == WebViewAssetLoader.DEFAULT_DOMAIN && request.url.path?.startsWith("/assets/character/") == true) assets.shouldInterceptRequest(request.url)
                else WebResourceResponse("text/plain", "utf-8", 404, "Not found", emptyMap(), null)
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) = true
            // The page's renderer died (memory pressure): Oby leaves the stage, the app stays.
            override fun onRenderProcessGone(view: WebView, detail: android.webkit.RenderProcessGoneDetail): Boolean {
                main.post { ready = false; loaded = false }
                return true
            }
            override fun onPageFinished(view: WebView, url: String) {
                loaded = true
                applyPause()
            }
        }
        addJavascriptInterface(CharacterBridge { event -> main.post { if (event == "ready") ready = true } }, "ObyAndroid")
        // oby.html posts its events to webkit.messageHandlers.oby (the iPhone's): the same name, here.
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(this,
                "window.webkit = { messageHandlers: { oby: { postMessage: function (m) { ObyAndroid.post(JSON.stringify(m)); } } } };",
                setOf("https://${WebViewAssetLoader.DEFAULT_DOMAIN}"))
        } else ready = true
        loadUrl("https://${WebViewAssetLoader.DEFAULT_DOMAIN}/assets/character/oby.html?embed&size=1.23")
    }

    /** The state Oby shows: idle, listening, thinking, working, loading or quiet. */
    var mood: String = "idle"
        set(value) {
            val old = field
            field = value
            if (!paused && value != old) run(if (old == "loading" && value != "listening") "oby.setState('$value', { finish: true })" else "oby.setState('$value', { now: true })")
        }

    /** A paused Oby draws nothing, so a hidden Home costs no CPU. */
    fun pause(on: Boolean) {
        if (on == paused) return
        paused = on
        applyPause()
    }

    private fun applyPause() {
        if (!paused) {
            view.onResume()
            run("oby.pause(false); oby.setState('$mood', { now: true })")
            return
        }
        // Look ahead and settle into a calm face first: paused mid-glance, Oby would freeze looking away.
        run("document.dispatchEvent(new PointerEvent('pointerleave')); oby.setState('quiet', { now: true })")
        main.postDelayed({ if (paused) { run("oby.pause(true)"); view.onPause() } }, 900)
    }

    private fun run(js: String) {
        if (!loaded) return
        view.evaluateJavascript("(function(){ if (!window.oby) return false; $js; return true; })()") { found ->
            if (found != "true") Log.e(Phone.TAG, "window.oby isn't on the page")
        }
    }
}
