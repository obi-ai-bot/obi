package com.deskree.oby

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.fragment.app.FragmentActivity
import kotlinx.coroutines.CompletableDeferred

/**
 * Oby on Android: a client of the runner through the paired Mac's gateway (docs/runner-api.md), as
 * the iPhone is. Sangam's design, light or dark as the system is (Settings › Appearance): Home, his
 * side panel, and no tab bar. In the background: no connection, and Oby draws nothing.
 */
class MainActivity : FragmentActivity() {
    private val phone get() = ObyApp.phone(this)
    private var appearance by mutableStateOf("system")
    /** Oby's page, made once for the activity so Home doesn't load it again each time it shows. */
    private val character by lazy { ObyCharacter(this) }
    private var waitingMic: CompletableDeferred<Boolean>? = null
    private var waitingCamera: CompletableDeferred<Boolean>? = null

    private val mic = registerForActivityResult(ActivityResultContracts.RequestPermission()) { waitingMic?.complete(it); waitingMic = null }
    private val camera = registerForActivityResult(ActivityResultContracts.RequestPermission()) { waitingCamera?.complete(it); waitingCamera = null }
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { if (it) Notifications.register(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        appearance = Store.prefs(this).getString(APPEARANCE, "system") ?: "system"
        phone.voice.askMicrophone = { ask(Manifest.permission.RECORD_AUDIO) }
        phone.askNotifications = { askNotifications() }
        Sample.apply(phone, intent)
        opened(intent)
        setContent {
            val dark = when (appearance) { "light" -> false; "dark" -> true; else -> isSystemInDarkTheme() }
            SideEffect {
                WindowCompat.getInsetsController(window, window.decorView).apply {
                    isAppearanceLightStatusBars = !dark
                    isAppearanceLightNavigationBars = !dark
                }
            }
            ObyTheme(dark) {
                CompositionLocalProvider(LocalCharacter provides character) {
                    PhoneRoot(phone, this, appearance = appearance, setAppearance = { appearance = it; Store.prefs(this).edit().putString(APPEARANCE, it).apply() })
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        opened(intent)
    }

    /** A notification was tapped: open its job, and publish it if that's what was tapped. */
    private fun opened(intent: Intent) {
        val job = intent.getStringExtra(Notifications.EXTRA_JOB) ?: return
        if (!Notifications.ours(this, intent)) return
        phone.open(job, intent.getBooleanExtra(Notifications.EXTRA_PUBLISH, false))
        intent.removeExtra(Notifications.EXTRA_JOB)
    }

    override fun onStart() {
        super.onStart()
        phone.start()
        Notifications.register(this)
    }

    override fun onStop() {
        // Leaving the app stops listening, keeps the words heard, and drops the connection.
        phone.leftForeground()
        phone.stop()
        JobsActivity.markStale(this, phone.jobs)
        super.onStop()
    }

    /** Asks once for a runtime permission, and answers whether it's allowed. */
    suspend fun ask(permission: String): Boolean {
        if (ContextCompat.checkSelfPermission(this, permission) == PackageManager.PERMISSION_GRANTED) return true
        val done = CompletableDeferred<Boolean>()
        when (permission) {
            Manifest.permission.RECORD_AUDIO -> { waitingMic = done; mic.launch(permission) }
            Manifest.permission.CAMERA -> { waitingCamera = done; camera.launch(permission) }
            else -> return false
        }
        return done.await()
    }

    /** Alerts when a job needs you: asked the first time Oby reaches the runner, as the iPhone does. */
    fun askNotifications() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) {
            Notifications.register(this)
            return
        }
        val prefs = Store.prefs(this)
        if (prefs.getBoolean("notifications.asked", false)) return
        prefs.edit().putBoolean("notifications.asked", true).apply()
        notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
    }

    fun openNotificationSettings() {
        startActivity(Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName))
    }

    companion object { const val APPEARANCE = "appearance" }
}
