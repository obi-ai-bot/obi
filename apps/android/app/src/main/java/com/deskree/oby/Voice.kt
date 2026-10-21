package com.deskree.oby

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import android.speech.tts.TextToSpeech
import android.view.textclassifier.TextClassificationManager
import android.view.textclassifier.TextLanguage
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.Locale

/** Settings › Voice (apps/shared/VoiceSettings.swift): the language Oby writes down what you say in. */
object VoiceSettings {
    const val LANGUAGE = "voice.language"
    const val SYSTEM_NAME = "Phone language"
    val languages = listOf("en-US" to "English", "pt-BR" to "Português (Brasil)", "pt-PT" to "Português (Portugal)")

    fun locale(selected: String?): Locale = if (selected == null || selected == "system") Locale.getDefault() else Locale.forLanguageTag(selected)
}

/**
 * One tap-to-dictate session (apps/ios/app/PhoneVoice.swift, AGENTS.md's voice rule): a tap on the
 * mic listens until Stop, at most 60 seconds; the words go into the draft as they're heard and stay
 * there; nothing is sent until the user sends it. Leaving the screen or the app stops listening.
 * Android's recognizer ends a segment on a pause, so while the session is wanted it listens again,
 * the words so far kept ahead of the new ones.
 */
class PhoneVoice(private val context: Context) {
    var active by mutableStateOf(false); private set
    var finishing by mutableStateOf(false); private set
    var listening by mutableStateOf(false); private set
    var level by mutableFloatStateOf(0f); private set
    var problem by mutableStateOf<String?>(null); private set

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var recognizer: SpeechRecognizer? = null
    private var update: ((String) -> Unit)? = null
    private var heard = ""
    private var partial = ""
    private var timeout: Job? = null
    private var generation = 0
    /** Set by the activity: asks for the microphone, and answers whether it's allowed. */
    var askMicrophone: (suspend () -> Boolean)? = null

    fun start(update: (String) -> Unit) {
        if (active || finishing) return
        cancel()
        active = true
        problem = null
        this.update = update
        heard = ""; partial = ""
        val token = generation
        scope.launch {
            val allowed = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED ||
                askMicrophone?.invoke() == true
            if (!active || generation != token) return@launch
            if (!allowed) { fail("Allow the microphone for Oby in Settings to talk. You can still type.", token); return@launch }
            if (!SpeechRecognizer.isRecognitionAvailable(context)) { fail("This phone can't write down speech. You can still type.", token); return@launch }
            listen(token)
            timeout = scope.launch {
                delay(60_000)
                if (generation == token) finish()
            }
        }
    }

    private fun listen(token: Int) {
        val r = recognizer ?: SpeechRecognizer.createSpeechRecognizer(context).also { recognizer = it }
        r.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) { if (generation == token) listening = true }
            override fun onBeginningOfSpeech() {}
            override fun onRmsChanged(rms: Float) { if (generation == token) level = ((rms + 2f) / 12f).coerceIn(0f, 1f) }
            override fun onBufferReceived(buffer: ByteArray?) {}
            override fun onEndOfSpeech() {}
            override fun onError(error: Int) {
                if (generation != token) return
                when {
                    // A pause or nothing heard: listen on while the session is wanted.
                    active && (error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT) -> listen(token)
                    finishing -> done(token)
                    else -> fail("Listening was interrupted. Tap the mic to try again.", token)
                }
            }
            override fun onResults(results: Bundle?) {
                if (generation != token) return
                val words = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                if (words.isNotBlank()) heard = Dictation.draft(heard, words.trim())
                partial = ""
                emit()
                if (active) listen(token) else done(token)
            }
            override fun onPartialResults(partialResults: Bundle?) {
                if (generation != token) return
                partial = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
                emit()
            }
            override fun onEvent(eventType: Int, params: Bundle?) {}
        })
        val locale = VoiceSettings.locale(Store.prefs(context).getString(VoiceSettings.LANGUAGE, "system"))
        r.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            // On this phone when it can: the words don't leave it to be written down.
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        })
    }

    private fun emit() {
        val words = if (partial.isBlank()) heard else Dictation.draft(heard, partial.trim())
        if (words.isNotEmpty()) update?.invoke(words)
    }

    /** Stop, or the 60-second limit: the last words go to the draft. Nothing is sent. */
    fun finish() {
        if (!active) return
        active = false
        listening = false
        level = 0f
        timeout?.cancel()
        val r = recognizer ?: return cancel()
        finishing = true
        r.stopListening()
        val token = generation
        // The recognizer doesn't always answer a stop: settle on what was heard.
        scope.launch { delay(2500); if (generation == token && finishing) done(token) }
    }

    private fun done(token: Int) {
        if (generation != token) return
        finishing = false
        if (heard.isBlank() && partial.isBlank()) problem = "Oby didn't catch that." else emit()
        update = null
        release()
    }

    /** Stops listening and drops any words still to come; those already in the draft stay. */
    fun cancel() {
        generation += 1
        active = false
        finishing = false
        listening = false
        level = 0f
        update = null
        timeout?.cancel()
        release()
    }

    private fun release() {
        recognizer?.cancel()
        recognizer?.destroy()
        recognizer = null
    }

    private fun fail(message: String, token: Int) {
        if (generation != token) return
        cancel()
        problem = message
    }
}

/** Reads replies to spoken requests out loud, in the reply's own language (TextClassifier), else the phone's. */
class PhoneSpeaker(private val context: Context) {
    private var tts: TextToSpeech? = null
    private var ready = false
    private var waiting: String? = null

    fun say(text: String) {
        stop()
        if (tts == null) tts = TextToSpeech(context) { status ->
            ready = status == TextToSpeech.SUCCESS
            waiting?.let { speak(it) }
            waiting = null
        }
        if (ready) speak(text) else waiting = text
    }

    private fun speak(text: String) {
        val engine = tts ?: return
        language(text)?.let { engine.setLanguage(it) }
        engine.speak(text, TextToSpeech.QUEUE_FLUSH, null, "oby")
    }

    private fun language(text: String): Locale? = runCatching {
        val classifier = context.getSystemService(TextClassificationManager::class.java).textClassifier
        val found = classifier.detectLanguage(TextLanguage.Request.Builder(text).build())
        found.getLocale(0).toLocale()
    }.getOrNull()

    fun stop() {
        waiting = null
        tts?.stop()
    }
}
