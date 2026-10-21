package com.deskree.oby

import android.Manifest
import android.content.ClipboardManager
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.Preview
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.core.content.ContextCompat
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import kotlinx.coroutines.launch

/**
 * Connect (docs/ios-design.md "Connect", apps/ios/app/ConnectScreen.swift): the first screen until this
 * phone pairs, and Settings › Your Mac after. Oby, "Connect to your Mac", where the Mac shows its code;
 * the QR code first ("Scan the code"), then an invitation pasted from a message, then the Macs on this
 * network and the six digits typed for one. Either buys the device token every gateway request carries.
 */
@Composable
fun ConnectScreen(first: Boolean) {
    val phone = LocalPhone.current
    val activity = LocalActivity.current
    val context = LocalContext.current
    val c = Tokens.c
    val scope = rememberCoroutineScope()
    var problem by remember { mutableStateOf<String?>(null) }
    var scanning by remember { mutableStateOf(false) }
    var code by remember { mutableStateOf("") }
    var chosen by remember { mutableStateOf(phone.link?.name ?: "") }
    var pairing by remember { mutableStateOf(false) }
    var unpairing by remember { mutableStateOf(false) }
    var another by remember { mutableStateOf(phone.runnerURL != null && phone.runnerURL != Runner.NOWHERE) }
    var address by remember { mutableStateOf(phone.runnerURL?.takeIf { it != Runner.NOWHERE } ?: "") }
    val browser = remember { MacFinder(context) }
    DisposableEffect(Unit) { browser.find(null); onDispose { browser.stop() } }
    val names = browser.names
    if (chosen.isEmpty() || (names.isNotEmpty() && chosen !in names && phone.link?.name != chosen)) chosen = names.firstOrNull() ?: chosen

    /** What the QR code said: the gateway's URL, the Mac's link and the one-time secret. */
    fun pair(value: String) {
        scope.launch {
            problem = try {
                val envelope = GatewayEnvelope.decode(value)
                phone.pairGateway(envelope.url, envelope.secret, envelope.link)
                null
            } catch (e: Exception) { e.message }
        }
    }

    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = Tokens.gutter).padding(bottom = 32.dp),
           horizontalAlignment = Alignment.CenterHorizontally) {
        Box(Modifier.padding(top = 24.dp)) { ObyMark(112.dp) }
        T("Connect to your Mac", 22.sp, c.ink, FontWeight.SemiBold, Modifier.padding(top = 20.dp).semantics { heading() })
        T("Oby on your Mac shows a code to pair with: Settings › Runner › Pair a device.", Tokens.textBase, c.text, center = true, modifier = Modifier.padding(top = 8.dp))
        val link = phone.link
        if (link != null && !phone.needsPairing) Box(Modifier.padding(top = 24.dp)) {
            SetGroup("Your Mac", rows = listOf(
                { SetRow(link.name, about = listOfNotNull(phone.route?.label, phone.pairedUntil?.let { "Paired until ${Format.monthDay(it)}" }).joinToString(" · ")) {
                    SetValue(phone.notice?.title ?: if (phone.connection == Connection.Live) "Connected" else "Connecting…", phone.connection == Connection.Live)
                } },
                { SetRow("Unpair", about = "Pair again with a new code.") { SetButton("Unpair", destructive = true) { unpairing = true } } },
            ))
        }
        PrimaryButton("Scan the code", Modifier.padding(top = 24.dp)) {
            problem = null
            scope.launch { if (activity.ask(Manifest.permission.CAMERA)) scanning = true else problem = "Allow the camera for Oby in Settings to scan the code, or paste the invitation." }
        }
        // The QR code's text, sent from wherever the Mac is: pairing from away.
        Row(Modifier.padding(top = 10.dp).height(40.dp).background(c.pill, CircleShape).clickable {
            val text = context.getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.coerceToText(context)?.toString()
            if (text.isNullOrBlank()) problem = "Copy the invitation from Oby on your Mac first." else pair(text)
        }.padding(horizontal = 18.dp), verticalAlignment = Alignment.CenterVertically) { T("Paste invitation", Tokens.textBase, c.item) }

        Column(Modifier.fillMaxWidth().padding(top = 28.dp)) {
            SetGroup("On this network", footer = "A code works once, for two minutes. This phone then stays paired for 30 days.", rows = buildList {
                if (names.isEmpty()) add { SetRow("Looking for Oby on this network…", quiet = true) }
                for (name in names) add { SetRow(name, onClick = { chosen = name }) { if (name == chosen) Icon(Icons.Filled.Check, null, tint = c.ink) } }
            })
            DigitBoxes(code) { code = it }
            val ready = !pairing && PairingCode.normalized(code) != null && chosen.isNotEmpty()
            PrimaryButton(if (pairing) "Connecting…" else "Connect", Modifier.padding(top = 16.dp).graphicsLayer { alpha = if (ready) 1f else 0.3f }, enabled = ready) {
                pairing = true
                scope.launch {
                    problem = try {
                        val digits = PairingCode.normalized(code) ?: throw RunnerError("The code is the six digits the Mac shows.")
                        val url = MacFinder.resolve(context, chosen)
                            ?: throw RunnerError("$chosen wasn't found on this network. Make sure the Mac is awake and on the same Wi-Fi, then try again.")
                        phone.pairGateway(url, digits)
                        code = ""
                        null
                    } catch (e: Exception) { e.message }
                    pairing = false
                }
            }
        }
        problem?.let { SetAbout(it, c.danger, Modifier.fillMaxWidth().padding(top = 12.dp)) }

        // A runner that isn't a Mac (one on a server you run), by its address: folded away, as most people pair their Mac.
        Column(Modifier.fillMaxWidth().padding(top = 28.dp)) {
            Row(Modifier.padding(horizontal = 16.dp).padding(bottom = 8.dp).clickable { another = !another }, verticalAlignment = Alignment.CenterVertically) {
                T("Another runner", Tokens.textMd, c.muted)
                Icon(Icons.Filled.ChevronRight, null, Modifier.size(14.dp).graphicsLayer { rotationZ = if (another) 90f else 0f }, tint = c.muted)
            }
            if (another) SetGroup(footer = "For a runner on a server of yours, not your Mac. Clear it to use only your Mac.", rows = listOf {
                SetRow("Address") {
                    SetField(address, "https://…", 200.dp, { address = it }, KeyboardOptions(keyboardType = KeyboardType.Uri)) {
                        val typed = address.trim()
                        when {
                            typed.isEmpty() -> { problem = null; phone.setRunner(null) }
                            !typed.startsWith("https://") -> problem = "The runner's address starts with https://"
                            typed != phone.runnerURL -> { problem = null; phone.setRunner(typed) }
                        }
                    }
                }
            })
        }
    }
    if (scanning) QRScanner({ scanning = false }) { value -> scanning = false; pair(value) }
    if (unpairing) AlertDialog(onDismissRequest = { unpairing = false }, containerColor = c.surface,
        title = { T("Unpair from ${phone.link?.name ?: "your Mac"}?", 17.sp, c.ink, FontWeight.SemiBold) },
        text = { T("This phone forgets its device token. Scan the code on your Mac to connect again.", Tokens.textBase, c.text) },
        confirmButton = { TextButton({ unpairing = false; phone.unpair(); if (!first) phone.homePath = emptyList() }) { T("Unpair", Tokens.textBase, c.danger) } },
        dismissButton = { TextButton({ unpairing = false }) { T("Cancel", Tokens.textBase, c.muted) } })
}

/** The screen's one `ink` button, full width. */
@Composable
private fun PrimaryButton(title: String, modifier: Modifier = Modifier, enabled: Boolean = true, onClick: () -> Unit) {
    val c = Tokens.c
    Box(modifier.fillMaxWidth().height(48.dp).background(c.ink, CircleShape).clickable(enabled = enabled, onClick = onClick), contentAlignment = Alignment.Center) {
        T(title, Tokens.textLg, c.onInk, FontWeight.Medium)
    }
}

/** Six boxes for the Mac's code: one field underneath, the digits shown in boxes, the next one edged while typing. */
@Composable
private fun DigitBoxes(code: String, onChange: (String) -> Unit) {
    val c = Tokens.c
    val focus = remember { FocusRequester() }
    var typing by remember { mutableStateOf(false) }
    val digits = code.filter { it.isDigit() }.take(6)
    Box(Modifier.fillMaxWidth().height(52.dp).clickable { focus.requestFocus() }) {
        BasicTextField(code, { typed -> onChange(typed.filter { it.isDigit() }.take(6)) }, Modifier.fillMaxSize().graphicsLayer { alpha = 0.02f }
            .focusRequester(focus).onFocusChanged { typing = it.isFocused }.semantics { contentDescription = "Six-digit code" },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.NumberPassword), singleLine = true, cursorBrush = SolidColor(Color.Transparent),
            textStyle = TextStyle(color = Color.Transparent))
        Row(Modifier.fillMaxSize(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            for (i in 0 until 6) Box(Modifier.weight(1f).fillMaxSize().background(c.field, RoundedCornerShape(12.dp))
                .border(1.dp, if (typing && i == minOf(digits.length, 5)) c.fieldEdgeOn else c.line, RoundedCornerShape(12.dp)), contentAlignment = Alignment.Center) {
                T(digits.getOrNull(i)?.toString() ?: "", 22.sp, c.ink, mono = true)
            }
        }
    }
}

/** The camera, full screen, until it sees a QR code (CameraX and ML Kit's on-device scanner: nothing leaves the phone). */
@androidx.annotation.OptIn(androidx.camera.core.ExperimentalGetImage::class)
@Composable
private fun QRScanner(close: () -> Unit, found: (String) -> Unit) {
    val context = LocalContext.current
    val owner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    var done by remember { mutableStateOf(false) }
    Dialog(close, DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        Box(Modifier.fillMaxSize().background(Color.Black)) {
            AndroidView({ ctx ->
                val view = PreviewView(ctx).apply { scaleType = PreviewView.ScaleType.FILL_CENTER }
                val future = ProcessCameraProvider.getInstance(ctx)
                future.addListener({
                    val provider = future.get()
                    val preview = Preview.Builder().build().also { it.surfaceProvider = view.surfaceProvider }
                    val scanner = BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(Barcode.FORMAT_QR_CODE).build())
                    val analysis = ImageAnalysis.Builder().setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST).build()
                    analysis.setAnalyzer(ContextCompat.getMainExecutor(ctx)) { proxy ->
                        val image = proxy.image
                        if (image == null || done) { proxy.close(); return@setAnalyzer }
                        scanner.process(InputImage.fromMediaImage(image, proxy.imageInfo.rotationDegrees))
                            .addOnSuccessListener { codes -> codes.firstNotNullOfOrNull { it.rawValue }?.let { if (!done) { done = true; found(it) } } }
                            .addOnCompleteListener { proxy.close() }
                    }
                    provider.unbindAll()
                    provider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                }, ContextCompat.getMainExecutor(ctx))
                view
            }, Modifier.fillMaxSize(), onRelease = { ProcessCameraProvider.getInstance(context).get().unbindAll() })
            Box(Modifier.align(Alignment.TopEnd).padding(top = 48.dp, end = 16.dp).size(40.dp).background(Color.White.copy(alpha = 0.2f), CircleShape)
                .clickable(onClick = close).semantics { contentDescription = "Close" }, contentAlignment = Alignment.Center) {
                Icon(Icons.Filled.Close, null, tint = Color.White)
            }
            T("Scan the code Oby shows on your Mac", Tokens.textBase, Color.White, center = true,
              modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 64.dp, start = 24.dp, end = 24.dp))
        }
    }
}
