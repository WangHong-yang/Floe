package com.floe.android

import android.app.Activity
import android.app.UiAutomation
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.SystemClock
import android.text.InputType
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.LinearLayout
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.floe.android.core.DictationBridge
import com.floe.android.core.DictationState
import com.floe.android.core.Phase
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Focus/overlay integration only: READY is injected; audio and inference are not exercised. */
@RunWith(AndroidJUnit4::class)
class EditorOverlayRegressionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private lateinit var device: UiDevice
    private var activity: Activity? = null
    private var originalServices: String? = null
    private var originalEnabled: String? = null
    private var settingsCaptured = false
    private var oldAutomationFlags = 0
    private var webView: WebView? = null
    private val overlay = By.desc("Floe voice input overlay")
    private val timeout = 30_000L

    @Before fun prepareSyntheticEmulator() {
        // Never alter accessibility configuration on a user's physical device.
        assumeTrue("Accessibility integration tests require a synthetic emulator",
            Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("Emulator") ||
                Build.MODEL.contains("sdk_gphone") || Build.HARDWARE in listOf("ranchu", "goldfish"))
        oldAutomationFlags = Configurator.getInstance().uiAutomationFlags
        Configurator.getInstance().setUiAutomationFlags(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        device = UiDevice.getInstance(instrumentation)
        originalServices = shell("settings get secure enabled_accessibility_services").trim()
        originalEnabled = shell("settings get secure accessibility_enabled").trim()
        // executeShellCommand tokenizes arguments itself; shell quotes become literal data.
        // Recover old malformed harness settings only on this guarded synthetic emulator.
        if (originalServices != "null" &&
            originalServices?.matches(Regex("[A-Za-z0-9_.:/]+")) != true) originalServices = "null"
        if (originalEnabled !in listOf("null", "0", "1")) originalEnabled = "0"
        settingsCaptured = true
        val service = "${instrumentation.targetContext.packageName}/.accessibility.FloeAccessibilityService"
        val existing = originalServices.orEmpty().takeUnless { it == "null" }.orEmpty()
        val services = (existing.split(':').filter { it.isNotBlank() } + service).distinct().joinToString(":")
        shell("settings put secure enabled_accessibility_services $services")
        shell("settings put secure accessibility_enabled 1")
        await("Floe accessibility service did not connect") { DictationBridge.accessibilityConnected.value }
        instrumentation.runOnMainSync { DictationBridge.update(DictationState(phase = Phase.READY)) }
        activity = instrumentation.startActivitySync(Intent(instrumentation.targetContext, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        device.waitForIdle()
    }

    @After fun restoreConfiguration() {
        if (!settingsCaptured) return
        try {
            instrumentation.runOnMainSync {
                DictationBridge.update(DictationState())
                webView?.destroy()
                activity?.finish()
            }
        } finally {
            restoreSetting("enabled_accessibility_services", originalServices)
            restoreSetting("accessibility_enabled", originalEnabled)
            Configurator.getInstance().setUiAutomationFlags(oldAutomationFlags)
        }
    }

    @Test fun ownComposeTextFieldRendersOverlayAndHomeHidesIt() {
        var field = device.findObject(By.res("floe_dictation_test_field"))
        repeat(7) {
            if (field == null) {
                device.swipe(device.displayWidth / 2, device.displayHeight * 4 / 5,
                    device.displayWidth / 2, device.displayHeight / 4, 35)
                field = device.wait(Until.findObject(By.res("floe_dictation_test_field")), 700)
            }
        }
        assertNotNull("Shipped Compose sample TextField must expose floe_dictation_test_field", field)
        clickEditor(field!!)
        assertOverlayVisible("compose-focused")
        val originalText = device.findObject(By.res("floe_dictation_test_field"))?.text.orEmpty()
        val preview = "Floe focus test ${SystemClock.uptimeMillis()}"
        diagnostic("original field text=$originalText; preview=$preview")
        var began = false
        instrumentation.runOnMainSync {
            began = DictationBridge.target?.begin() == true
        }
        assertTrue("Focused Compose editor must become a real insertion target", began)
        try {
            instrumentation.runOnMainSync { DictationBridge.target?.partial(preview) }
            await("Live preview must appear in the actual Compose field") {
                device.findObject(By.res("floe_dictation_test_field"))?.text?.contains(preview) == true
            }
            capture("compose-live-preview")
            diagnostic("before cancel field=" + device.findObject(By.res("floe_dictation_test_field"))?.text)
            recordInsertionDiagnostics()
        } finally {
            instrumentation.runOnMainSync { DictationBridge.target?.cancel() }
        }
        diagnostic("after cancel field=" + device.findObject(By.res("floe_dictation_test_field"))?.text)
        await("Cancel must restore the original Compose field text") {
            val currentField = device.findObject(By.res("floe_dictation_test_field"))
            currentField != null && currentField.text.orEmpty() == originalText
        }
        capture("compose-preview-cancelled")
        device.pressHome()
        assertOverlayHidden("home")
    }

    @Test fun nativeEditorsSwitchAndPasswordAndNonEditorHideOverlay() {
        installNativeFixture()
        clickEditor(find("Native first"))
        assertOverlayVisible("native-first")
        clickEditor(find("Native second"))
        assertOverlayVisible("native-second")
        clickEditor(find("Native password"))
        assertOverlayHidden("native-password")
        clickEditor(find("Native first"))
        assertOverlayVisible("native-return")
        find("Clear editor focus").click()
        assertOverlayHidden("native-cleared")
    }

    @Test fun webViewVirtualInputRendersOverlayAndPasswordHidesIt() {
        val pageLoaded = java.util.concurrent.atomic.AtomicBoolean(false)
        instrumentation.runOnMainSync {
            val host = requireNotNull(activity)
            webView = WebView(host).apply {
                webViewClient = object : WebViewClient() {
                    override fun onPageFinished(view: WebView?, url: String?) { pageLoaded.set(true) }
                }
                setBackgroundColor(Color.WHITE)
                loadDataWithBaseURL("https://floe.test/", """
                    <!doctype html><html lang="en"><head><meta name="viewport" content="width=device-width, initial-scale=1"></head>
                    <body style="font:20px sans-serif;padding:20px">
                    <label for="plain">Web normal</label><input id="plain" aria-label="Web normal" type="text" style="display:block;width:90%;height:55px;margin-bottom:24px">
                    <label for="secret">Web password</label><input id="secret" aria-label="Web password" type="password" style="display:block;width:90%;height:55px">
                    </body></html>
                """.trimIndent(), "text/html", "UTF-8", null)
            }
            host.setContentView(webView)
        }
        await("WebView fixture page did not finish loading") { pageLoaded.get() }
        capture("web-loaded")
        val normal = webEditor("Web normal")
        clickEditor(normal)
        assertOverlayVisible("web-normal")
        clickEditor(webEditor("Web password"))
        assertOverlayHidden("web-password")
        clickEditor(webEditor("Web normal"))
        assertOverlayVisible("web-return")
        device.pressHome()
        assertOverlayHidden("web-home")
    }

    private fun installNativeFixture() = instrumentation.runOnMainSync {
        val host = requireNotNull(activity)
        val root = LinearLayout(host).apply {
            orientation = LinearLayout.VERTICAL
            isFocusableInTouchMode = true
            setPadding(24, 48, 24, 24)
            setBackgroundColor(Color.WHITE)
        }
        listOf("Native first", "Native second", "Native password").forEach { label ->
            root.addView(EditText(host).apply {
                contentDescription = label
                hint = label
                inputType = if (label.endsWith("password"))
                    InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD else InputType.TYPE_CLASS_TEXT
            }, LinearLayout.LayoutParams(-1, 140))
        }
        root.addView(Button(host).apply {
            text = "Clear editor focus"
            contentDescription = "Clear editor focus"
            setOnClickListener {
                root.requestFocus()
                (host.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager)
                    .hideSoftInputFromWindow(root.windowToken, 0)
            }
        })
        host.setContentView(root)
        root.requestFocus()
    }

    private fun webEditor(label: String): UiObject2 {
        // Chromium's input controls are virtual EditText nodes, not native child Views.
        // API30 WebView exposes the DOM id as resource-id; labels are siblings,
        // and aria-label is not reliably reflected in text/content-description.
        val domId = when (label) {
            "Web normal" -> "plain"
            "Web password" -> "secret"
            else -> error("Unknown WebView fixture editor: $label")
        }
        var result: UiObject2? = null
        await("WebView input '$label' missing from accessibility tree") {
            result = device.findObject(By.clazz("android.widget.EditText").res(domId))
            result != null
        }
        return result!!
    }

    private fun find(description: String): UiObject2 = requireNotNull(device.wait(Until.findObject(By.desc(description)), timeout)) {
        "Missing fixture: $description"
    }

    private fun clickEditor(editor: UiObject2) {
        // The overlay can legitimately overlap an editor's center. Tap inside its
        // left edge so this regression measures focus resolution, not interception.
        val bounds = editor.visibleBounds
        assertFalse("Editor must be visible before tapping", bounds.isEmpty)
        device.click(bounds.left + minOf(24, (bounds.width() - 1) / 2), bounds.centerY())
    }

    private fun assertOverlayVisible(name: String) {
        val node = device.wait(Until.findObject(overlay), timeout)
        capture(name)
        assertNotNull("Actual accessibility overlay must be rendered: $name", node)
        assertFalse("Overlay must have visible on-screen bounds", node!!.visibleBounds.isEmpty)
    }

    private fun assertOverlayHidden(name: String) {
        val disappeared = device.wait(Until.gone(overlay), timeout)
        if (!disappeared) capture("failure-$name")
        assertTrue("Overlay must disappear: $name", disappeared)
        // Check beyond a scanner debounce to catch an immediate stale-focus reappearance.
        SystemClock.sleep(700)
        capture(name)
        assertFalse("Overlay reappeared after losing eligible focus: $name", device.hasObject(overlay))
    }

    private fun diagnostic(message: String) {
        val directory = File(instrumentation.targetContext.filesDir, "focus-regression").apply { mkdirs() }
        File(directory, "compose-diagnostics.txt").appendText("${SystemClock.uptimeMillis()} $message\n")
        android.util.Log.i("FloeFocusRegression", message)
    }

    @Suppress("DEPRECATION")
    private fun recordInsertionDiagnostics() = instrumentation.runOnMainSync {
        // Only this emulator-only test reads private state. Never part of the app build.
        runCatching {
            val target = requireNotNull(DictationBridge.target)
            fun privateValue(name: String): Any? = target.javaClass.getDeclaredField(name)
                .apply { isAccessible = true }.get(target)
            val edit = privateValue("edit") as? com.floe.android.core.TranscriptEdit
            diagnostic("session original=${edit?.original}; expected=${edit?.expected}; wrote=${edit?.wrote}")
            val node = privateValue("sessionNode") as? android.view.accessibility.AccessibilityNodeInfo
            if (node != null) {
                val copy = android.view.accessibility.AccessibilityNodeInfo.obtain(node)
                try { diagnostic("session clone refresh=${copy.refresh()}; text=${copy.text}; password=${copy.isPassword}") }
                finally { copy.recycle() }
            } else diagnostic("session node absent")
        }.onFailure { diagnostic("diagnostic reflection failed: $it") }
    }

    private fun capture(name: String) {
        val directory = File(instrumentation.targetContext.filesDir, "focus-regression").apply { mkdirs() }
        device.takeScreenshot(File(directory, "$name.png"))
        device.dumpWindowHierarchy(File(directory, "$name.xml"))
    }

    private fun await(message: String, condition: () -> Boolean) {
        val deadline = SystemClock.uptimeMillis() + timeout
        while (SystemClock.uptimeMillis() < deadline) {
            if (condition()) return
            SystemClock.sleep(100)
        }
        val passed = condition()
        if (!passed) capture("failure-" + message.take(60).replace(Regex("[^A-Za-z0-9]+"), "-"))
        assertTrue(message, passed)
    }

    private fun shell(command: String): String = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).executeShellCommand(command)
        .use { descriptor -> java.io.FileInputStream(descriptor.fileDescriptor).bufferedReader().use { it.readText() } }

    private fun restoreSetting(key: String, value: String?) {
        if (value == null || value == "null") shell("settings delete secure $key")
        else shell("settings put secure $key $value")
    }
}
