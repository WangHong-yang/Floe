package com.floe.android

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Image
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.floe.android.service.FloeNotifications
import com.floe.android.core.DictationBridge
import com.floe.android.core.DictationState
import com.floe.android.core.Phase
import com.floe.android.core.FloePreferences

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge(
            statusBarStyle = SystemBarStyle.dark(android.graphics.Color.BLACK),
            navigationBarStyle = SystemBarStyle.dark(android.graphics.Color.BLACK)
        )
        setContent { FloeTheme { FloeScreen() } }
    }
}

// Always black, including when Android uses a light theme.
@Composable
private fun FloeTheme(content: @Composable () -> Unit) {
    val colors = darkColorScheme(
        primary = Color.White, onPrimary = Color.Black,
        primaryContainer = Color(0xFF242424), onPrimaryContainer = Color.White,
        secondary = Color(0xFFD0D0D0), onSecondary = Color.Black,
        background = Color.Black, onBackground = Color.White,
        surface = Color.Black, onSurface = Color.White,
        surfaceContainer = Color.Black, surfaceContainerHigh = Color(0xFF121212),
        surfaceContainerHighest = Color(0xFF1A1A1A),
        onSurfaceVariant = Color(0xFFA6A6A6),
        outline = Color(0xFF686868), outlineVariant = Color(0xFF292929)
    )
    MaterialTheme(colorScheme = colors, typography = Typography(), content = content)
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun FloeScreen() {
    val context = LocalContext.current
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    val preferences = remember { FloePreferences(context) }
    val state by DictationBridge.state.collectAsState()
    val connected by DictationBridge.accessibilityConnected.collectAsState()
    val running by DictationBridge.serviceRunning.collectAsState()
    var microphone by remember { mutableStateOf(false) }
    var disclosure by rememberSaveable { mutableStateOf(false) }
    var micDenied by rememberSaveable { mutableStateOf(false) }
    var liveInsertion by remember { mutableStateOf(preferences.liveInsertion) }
    // Demo text is transient too: do not persist dictated content in saved instance state.
    var sample by remember { mutableStateOf("") }
    val clipboard = LocalClipboardManager.current
    val microphoneRequest = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) {
        microphone = it
        micDenied = !it
    }
    val notificationRequest = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted && DictationBridge.serviceRunning.value && DictationBridge.state.value.phase in setOf(Phase.READY, Phase.PREPARING))
            FloeNotifications.showStandby(context)
    }
    DisposableEffect(lifecycle) {
        fun refresh() {
            microphone = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
        }
        refresh()
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refresh() }
        lifecycle.addObserver(observer)
        onDispose { lifecycle.removeObserver(observer) }
    }
    Surface(color = Color.Black) {
        Column(Modifier.fillMaxSize().semantics { testTagsAsResourceId = true }.safeDrawingPadding()
            .imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp, vertical = 20.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp)) {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Floe", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Medium,
                        letterSpacing = (-1).sp)
                    Text("Offline voice typing", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Image(painterResource(R.drawable.floe_ice), "Floe silver ice logo",
                    Modifier.size(84.dp), contentScale = ContentScale.Fit)
            }
            FloeSection {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(if (running) "Floe is on" else "Enable Floe", style = MaterialTheme.typography.titleLarge)
                        Text(when (state.phase) {
                            Phase.OFF -> "Off"
                            Phase.PREPARING -> "Preparing the offline model"
                            Phase.LOADING -> "Starting the microphone"
                            Phase.READY -> "Ready to dictate"
                            Phase.RECORDING -> "Listening"
                            Phase.FINISHING -> "Finishing your text"
                            Phase.ERROR -> "Needs attention"
                        },
                            color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge,
                            modifier = Modifier.padding(top = 4.dp))
                    }
                    Switch(checked = running, enabled = running || (microphone && connected),
                        onCheckedChange = { enabled ->
                            if (enabled) {
                                try {
                                    DictationBridge.enable?.invoke()
                                } catch (error: RuntimeException) {
                                    DictationBridge.update(DictationState(Phase.ERROR, state.transcript,
                                        "Could not start Floe. Check microphone permission and try again with the app open."))
                                    return@Switch
                                }
                                if (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context,
                                        Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED)
                                    notificationRequest.launch(Manifest.permission.POST_NOTIFICATIONS)
                            } else DictationBridge.disable?.invoke()
                        }, modifier = Modifier.testTag("floe_service_toggle"))
                }
                if (state.message.isNotBlank()) Text(state.message, style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("The floating ice stays available. Your microphone stays off until you start dictation. Standby uses a silent drawer notification, without a status-bar icon on standard Android. Allow notifications to see it; device settings may change how it appears.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (!microphone || !connected) FloeSection {
                Text("Before you begin", style = MaterialTheme.typography.titleLarge)
                if (!microphone) {
                    OutlinedButton(onClick = { microphoneRequest.launch(Manifest.permission.RECORD_AUDIO) },
                        modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(8.dp)) { Text("Allow microphone access") }
                    if (micDenied) TextButton(onClick = {
                        context.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}")))
                    }) { Text("Open app permissions") }
                }
                if (!connected) OutlinedButton(onClick = { disclosure = true }, modifier = Modifier.fillMaxWidth(),
                    shape = RoundedCornerShape(8.dp)) { Text("Set up accessibility typing") }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            FloeSection {
                Text("Try it here", style = MaterialTheme.typography.titleLarge)
                Text("Tap the text field, then use the floating voice button.", color = MaterialTheme.colorScheme.onSurfaceVariant)
                TextField(value = sample, onValueChange = { sample = it },
                    modifier = Modifier.fillMaxWidth().testTag("floe_dictation_test_field"),
                    label = { Text("Your words") }, placeholder = { Text("Tap here and try saying something…") },
                    minLines = 2,
                    colors = TextFieldDefaults.colors(
                        focusedContainerColor = Color.Black,
                        unfocusedContainerColor = Color.Black,
                        disabledContainerColor = Color.Black,
                        focusedIndicatorColor = Color.White,
                        unfocusedIndicatorColor = MaterialTheme.colorScheme.outline,
                        cursorColor = Color.White
                    ))
                Text("Tap the ice to start and finish, or hold to talk and release to finish. Wait for the red dot and a second light vibration before speaking.\n\nDrag to move. During recording, × cancels and ✓ finishes. The model loads once when you enable Floe and stays in memory until you disable it. Idle does not record or run speech inference.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (state.transcript.isNotBlank()) FloeSection {
                Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                    Text("Latest transcript", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge)
                    TextButton(onClick = { clipboard.setText(AnnotatedString(state.transcript)) }) { Text("Copy") }
                }
                Text(state.transcript, modifier = Modifier.testTag("floe_latest_transcript"))
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            FloeSection {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text("Live typing", style = MaterialTheme.typography.titleMedium)
                        Text("Type recognized words into the current text field as you speak.", style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    Switch(checked = liveInsertion, onCheckedChange = {
                        liveInsertion = it; preferences.liveInsertion = it
                    })
                }
                TextButton(onClick = { preferences.overlayPosition = null; DictationBridge.resetOverlay?.invoke() }) {
                    Text("Reset floating control position")
                }
            }
            Text("Speech stays on your device. No cloud uploads.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 4.dp))
        }
    }
    if (disclosure) AlertDialog(onDismissRequest = { disclosure = false },
        containerColor = Color.Black, tonalElevation = 0.dp,
        shape = RoundedCornerShape(12.dp),
        title = { Text("Let Floe type your words") },
        text = { Text("Floe uses Android Accessibility to show a floating voice control and read the focused text field so it can insert your words. It does not process password fields or save recordings or text field history. Speech recognition runs entirely on your device.\n\nIf an app does not support direct typing, Floe will let you know when the transcript is copied to the system clipboard for manual pasting. You can also view and copy your latest transcript on this page.\n\nYou can turn off this permission in Settings at any time. To continue, select Floe and enable its accessibility service.",
            modifier = Modifier.heightIn(max = 360.dp).verticalScroll(rememberScrollState())) },
        confirmButton = { TextButton(onClick = {
            disclosure = false
            context.startActivity(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
        }) { Text("Continue to Settings") } },
        dismissButton = { TextButton(onClick = { disclosure = false }) { Text("Not now") } })
}

@Composable
private fun FloeSection(content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
}
