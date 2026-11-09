package com.floe.android.service

import android.app.Activity
import android.app.UiAutomation
import android.app.Notification
import android.app.NotificationManager
import android.content.Intent
import android.media.AudioManager
import android.os.Build
import android.os.Process
import android.os.SystemClock
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.Configurator
import com.floe.android.MainActivity
import com.floe.android.core.*
import kotlinx.coroutines.sync.Mutex
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/** Real bundled model and AudioRecord checks, only on a dedicated synthetic emulator.
 * Silence does not validate speech accuracy, physical latency, battery use or vibration.
 * Metrics include instrumentation/emulator overhead and are not phone benchmarks. */
@RunWith(AndroidJUnit4::class)
class DictationPowerLifecycleTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext
    private var activity: Activity? = null
    private var previousTarget: InsertionTarget? = null
    private var setup = false
    private var cancelled = 0
    private lateinit var service: DictationController
    private var originalServices: String? = null
    private var originalEnabled: String? = null
    private var oldAutomationFlags = 0

    @Before fun enableOnEmulator() {
        assumeTrue("Power tests must not change a physical device's permissions",
            Build.FINGERPRINT.contains("generic") || Build.MODEL.contains("Emulator") ||
                Build.MODEL.contains("sdk_gphone") || Build.HARDWARE in listOf("ranchu", "goldfish"))
        shell("pm grant ${context.packageName} android.permission.RECORD_AUDIO")
        if (Build.VERSION.SDK_INT >= 33) shell("pm grant ${context.packageName} android.permission.POST_NOTIFICATIONS")
        oldAutomationFlags = Configurator.getInstance().uiAutomationFlags
        Configurator.getInstance().setUiAutomationFlags(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES)
        originalServices = shell("settings get secure enabled_accessibility_services").trim()
        originalEnabled = shell("settings get secure accessibility_enabled").trim()
        if (originalServices != "null" && originalServices?.matches(Regex("[A-Za-z0-9_.:/]+")) != true) originalServices = "null"
        if (originalEnabled !in listOf("null", "0", "1")) originalEnabled = "0"
        setup = true
        val component = "${context.packageName}/.accessibility.FloeAccessibilityService"
        val existing = originalServices.orEmpty().takeUnless { it == "null" }.orEmpty()
        val services = (existing.split(':').filter { it.isNotBlank() } + component).distinct().joinToString(":")
        shell("settings put secure enabled_accessibility_services $services")
        shell("settings put secure accessibility_enabled 1")
        await("system-bound accessibility connected") { DictationBridge.accessibilityConnected.value }
        activity = instrumentation.startActivitySync(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        val enabledAt = SystemClock.elapsedRealtime()
        instrumentation.runOnMainSync {
            previousTarget = DictationBridge.target
            DictationBridge.update(DictationState())
            DictationBridge.target = object : InsertionTarget {
                override fun begin() = true
                override fun partial(text: String) = Unit
                override fun finish(text: String) = "Test text inserted"
                override fun cancel() { cancelled++ }
            }
            DictationBridge.enable!!.invoke()
        }
        await("preloaded service READY") {
            assertFalse("Preloading must not open AudioRecord", recording())
            DictationBridge.state.value.phase == Phase.READY
        }
        service = boundService()
        metric("Enable to preloaded READY: ${SystemClock.elapsedRealtime() - enabledAt} ms")
    }

    @After fun disableAndRestore() {
        if (!setup) return
        instrumentation.runOnMainSync { DictationBridge.disable?.invoke() }
        await("service stopped") { !DictationBridge.serviceRunning.value }
        await("worker released") { !asrWorkerExists() }
        assertFalse("Disabling must close AudioRecord", recording())
        if (::service.isInitialized) await("model owner released") { modelOwner() == null }
        instrumentation.runOnMainSync {
            DictationBridge.target = previousTarget
            activity?.finish()
        }
        restoreSetting("enabled_accessibility_services", originalServices)
        restoreSetting("accessibility_enabled", originalEnabled)
        Configurator.getInstance().setUiAutomationFlags(oldAutomationFlags)
        // Revoking microphone permission would kill instrumentation. Emulator runner owns cleanup.
    }

    @Test fun enabledIdleRetainsModelWithNoMicrophoneOrSession() {
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        assertIdle("enabled", owner, native)
        val cpuBefore = Process.getElapsedCpuTime()
        val start = SystemClock.elapsedRealtime()
        SystemClock.sleep(2_000)
        metric("Enabled idle observation: wall=${SystemClock.elapsedRealtime() - start} ms; " +
            "whole-process CPU=${Process.getElapsedCpuTime() - cpuBefore} ms (includes test/UI overhead)")
        assertIdle("enabled-after-wait", owner, native)
        await("idle ASR worker parked") {
            Thread.getAllStackTraces().keys.any {
                it.isAlive && it.name == "Floe-ASR" &&
                    it.state in listOf(Thread.State.WAITING, Thread.State.TIMED_WAITING)
            }
        }
    }

    @Test fun cancelQueuedStartNeverOpensMicrophoneAndKeepsModel() {
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        // Hold the real service operation boundary to deterministically cancel before engine.start.
        // A same-main-turn cancel alone cannot prove that an IO thread never opened the recorder.
        val operations = field(service, "operations") as Mutex
        assertTrue(operations.tryLock())
        try {
            instrumentation.runOnMainSync {
                DictationBridge.start!!.invoke()
                assertEquals(Phase.LOADING, DictationBridge.state.value.phase)
                DictationBridge.finish!!.invoke()
                assertEquals(Phase.FINISHING, DictationBridge.state.value.phase)
                repeat(3) { DictationBridge.start!!.invoke() }
            }
            assertFalse("Cancelled queued start must not open AudioRecord", recording())
            assertNull("No recognizer session may start while operation is queued", field(owner, "session"))
        } finally { operations.unlock() }
        await("queued cancel READY") {
            assertFalse("Cancelled queued start must never open AudioRecord", recording())
            assertNotEquals(Phase.RECORDING, DictationBridge.state.value.phase)
            DictationBridge.state.value.phase == Phase.READY
        }
        assertEquals(1, cancelled)
        assertIdle("queued-cancel", owner, native)
    }

    @Test fun cancelBeforeForegroundHandshakeNeverOpensMicrophone() {
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        // The same main turn requests the service and cancels before Android can
        // dispatch its onStartCommand. This exercises the real pending-FGS path.
        instrumentation.runOnMainSync {
            DictationBridge.start!!.invoke()
            assertEquals(Phase.LOADING, DictationBridge.state.value.phase)
            assertNotNull("Microphone service request must be pending", MicrophoneSession.current)
            assertNull("No utterance before foreground readiness", field(owner, "session"))
            DictationBridge.finish!!.invoke()
        }
        await("pending foreground request cancelled") {
            assertFalse("Cancelled handshake must not record", recording())
            DictationBridge.state.value.phase == Phase.READY
        }
        // Also exceed Android's usual foreground-promotion deadline: cancelling
        // a queued start must stop its service rather than leave a timeout crash.
        SystemClock.sleep(6_000)
        assertIdle("cancelled-foreground-handshake", owner, native)
    }

    @Test fun disableBeforeForegroundHandshakeReleasesAllResources() {
        instrumentation.runOnMainSync {
            DictationBridge.start!!.invoke()
            assertEquals(Phase.LOADING, DictationBridge.state.value.phase)
            DictationBridge.disable!!.invoke()
        }
        await("pending foreground request disabled") {
            assertFalse("Disable before ready must not record", recording())
            !DictationBridge.serviceRunning.value && !asrWorkerExists() && modelOwner() == null
        }
        SystemClock.sleep(6_000)
        assertNull(MicrophoneSession.current)
        assertNull(MicrophoneSession.service)
        assertEquals(Phase.OFF, DictationBridge.state.value.phase)
    }

    @Test fun repeatedRecordingFinishAndCancelReuseSameModel() {
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        repeat(2) { cycle ->
            startAndAwaitRecording("finish-$cycle")
            assertForegroundType(true, "recording-before-finish-$cycle")
            instrumentation.runOnMainSync { DictationBridge.finish!!.invoke() }
            await("finish READY") { DictationBridge.state.value.phase == Phase.READY }
            assertIdle("finished-$cycle", owner, native)
            startAndAwaitRecording("cancel-$cycle")
            assertForegroundType(true, "recording-before-cancel-$cycle")
            instrumentation.runOnMainSync { DictationBridge.cancel!!.invoke() }
            await("cancel READY") { DictationBridge.state.value.phase == Phase.READY }
            assertIdle("cancelled-$cycle", owner, native)
        }
    }

    @Test fun staleStoppedCallbackCannotClearNewRecordingForegroundType() {
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        startAndAwaitRecording("stale-callback-first")
        val oldSession = checkNotNull(field(owner, "session"))
        @Suppress("UNCHECKED_CAST")
        val oldStopped = field(oldSession, "onStopped") as () -> Unit
        instrumentation.runOnMainSync { DictationBridge.finish!!.invoke() }
        await("first session finished") { DictationBridge.state.value.phase == Phase.READY }
        assertIdle("before-stale-callback", owner, native)
        startAndAwaitRecording("stale-callback-second")
        instrumentation.runOnMainSync { oldStopped() }
        assertForegroundType(true, "after-stale-stopped")
        assertEquals(Phase.RECORDING, DictationBridge.state.value.phase)
        assertTrue("New AudioRecord must remain active", recording())
        assertSame(owner, modelOwner())
        instrumentation.runOnMainSync { DictationBridge.cancel!!.invoke() }
        await("second session cancelled") { DictationBridge.state.value.phase == Phase.READY }
        assertIdle("after-stale-callback", owner, native)
    }

    @Test fun screenOffStopsRecordingButKeepsWarmModel() {
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        startAndAwaitRecording("screen-off")
        try {
            shell("input keyevent 223") // Actual protected screen-off broadcast.
            await("screen-off READY") { DictationBridge.state.value.phase == Phase.READY }
            assertIdle("screen-off", owner, native)
        } finally {
            shell("input keyevent 224")
            shell("wm dismiss-keyguard")
        }
    }

    @Test fun rapidReenableWaitsForPreviousModelRelease() {
        val oldService = service
        val oldOwner = checkNotNull(modelOwner())
        val oldNative = checkNotNull(nativeModel(oldOwner))
        val operations = field(oldService, "operations") as Mutex
        // Delay old service cleanup without blocking Android's main thread. This exercises the
        // process-wide model lease even if native model construction is very fast on this device.
        assertTrue(operations.tryLock())
        try {
            instrumentation.runOnMainSync { DictationBridge.disable?.invoke() }
            await("old service destroyed with cleanup queued") { !DictationBridge.serviceRunning.value }
            instrumentation.runOnMainSync { DictationBridge.enable!!.invoke() }
            await("replacement preparing") {
                DictationBridge.serviceRunning.value && DictationBridge.state.value.phase == Phase.PREPARING
            }
            service = boundService()
            assertNotSame("A new service instance is required", oldService, service)
            val nextOwner = checkNotNull(modelOwner())
            assertNotSame(oldOwner, nextOwner)
            // Give the replacement worker a chance to attempt preparation while the lease is held.
            SystemClock.sleep(500)
            assertEquals(Phase.PREPARING, DictationBridge.state.value.phase)
            assertSame("Old model has not been released yet", oldNative, nativeModel(oldOwner))
            assertNull("Replacement must not allocate a second model while old close is pending", nativeModel(nextOwner))
            assertFalse("Waiting for previous model must never record", recording())
        } finally { operations.unlock() }
        await("replacement READY after previous cleanup") {
            assertFalse("Re-enabling must not record", recording())
            DictationBridge.state.value.phase == Phase.READY && field(oldService, "recognizer") == null
        }
        assertNull("Previous native model must be released", nativeModel(oldOwner))
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        assertIdle("rapid-reenable", owner, native)
        startAndAwaitRecording("rapid-reenable")
        instrumentation.runOnMainSync { DictationBridge.cancel!!.invoke() }
        await("replacement cancel READY") { DictationBridge.state.value.phase == Phase.READY }
        assertIdle("rapid-reenable-after-cancel", owner, native)
    }

    @Test fun stoppedReplacementWaitingForLeaseDoesNotBlockNextEnable() {
        val firstService = service
        val staleFinish = checkNotNull(DictationBridge.finish)
        val staleCancel = checkNotNull(DictationBridge.cancel)
        val firstOwner = checkNotNull(modelOwner())
        val firstNative = checkNotNull(nativeModel(firstOwner))
        val operations = field(firstService, "operations") as Mutex
        var secondService: DictationController? = null
        var secondOwner: Any? = null
        assertTrue(operations.tryLock())
        try {
            instrumentation.runOnMainSync { DictationBridge.disable?.invoke() }
            await("first service destroyed, close queued") { !DictationBridge.serviceRunning.value }
            instrumentation.runOnMainSync { DictationBridge.enable!!.invoke() }
            await("second service waiting for lease") {
                DictationBridge.serviceRunning.value && DictationBridge.state.value.phase == Phase.PREPARING
            }
            secondService = boundService()
            service = secondService
            secondOwner = checkNotNull(modelOwner())
            SystemClock.sleep(500)
            assertNull("Second model must wait for the first", nativeModel(secondOwner))
            instrumentation.runOnMainSync { DictationBridge.disable?.invoke() }
            await("second service destroyed while waiting") { !DictationBridge.serviceRunning.value }
            assertEquals(Phase.OFF, DictationBridge.state.value.phase)
            assertSame(firstNative, nativeModel(firstOwner))
            instrumentation.runOnMainSync { DictationBridge.enable!!.invoke() }
            await("third service preparing") {
                DictationBridge.serviceRunning.value && DictationBridge.state.value.phase == Phase.PREPARING
            }
            service = boundService()
            assertNotSame(firstService, service)
            assertNotSame(secondService, service)
            val thirdOwner = checkNotNull(modelOwner())
            SystemClock.sleep(500)
            assertEquals(Phase.PREPARING, DictationBridge.state.value.phase)
            assertNull("Stopped second must not construct a model", nativeModel(secondOwner))
            assertNull("Third must wait until first releases native memory", nativeModel(thirdOwner))
            assertFalse("Lease wait must not record", recording())
        } finally { operations.unlock() }
        val stoppedService = checkNotNull(secondService)
        val stoppedOwner = checkNotNull(secondOwner)
        await("third READY after both predecessor cleanups") {
            assertFalse("Enable after a stopped waiter must not record", recording())
            DictationBridge.state.value.phase == Phase.READY &&
                field(firstService, "recognizer") == null && field(stoppedService, "recognizer") == null
        }
        assertNull(nativeModel(firstOwner))
        assertNull("Stopped waiter's lease must be released without retaining a model", nativeModel(stoppedOwner))
        val owner = checkNotNull(modelOwner())
        val native = checkNotNull(nativeModel(owner))
        assertIdle("stopped-lease-waiter", owner, native)
        startAndAwaitRecording("after-stopped-lease-waiter")
        instrumentation.runOnMainSync {
            staleFinish()
            staleCancel()
        }
        assertEquals("Destroyed service callbacks must not mutate replacement state", Phase.RECORDING, DictationBridge.state.value.phase)
        assertTrue("Destroyed service callbacks must not stop replacement microphone", recording())
        assertForegroundType(true, "after-stale-service-bridge-callbacks")
        instrumentation.runOnMainSync { DictationBridge.cancel!!.invoke() }
        await("third cancel READY") { DictationBridge.state.value.phase == Phase.READY }
        assertIdle("stopped-lease-waiter-after-cancel", owner, native)
    }

    @Test fun disableDuringRecordingReleasesMicrophoneModelAndWorker() {
        startAndAwaitRecording("disable-recording")
        instrumentation.runOnMainSync { DictationBridge.disable?.invoke() }
        await("active recording disable cleanup") {
            !DictationBridge.serviceRunning.value && !asrWorkerExists() && modelOwner() == null
        }
        assertFalse("Disable must release actual microphone", recording())
        assertEquals(Phase.OFF, DictationBridge.state.value.phase)
    }

    @Test fun disableDuringPreloadNeverRecordsAndEventuallyReleasesModel() {
        instrumentation.runOnMainSync { DictationBridge.disable?.invoke() }
        await("old service stopped") { !DictationBridge.serviceRunning.value }
        await("old worker and model released") { !asrWorkerExists() && modelOwner() == null }
        instrumentation.runOnMainSync { DictationBridge.enable!!.invoke() }
        await("new service PREPARING", intervalMs = 5) {
            assertFalse("Preloading must not record", recording())
            DictationBridge.state.value.phase == Phase.PREPARING
        }
        instrumentation.runOnMainSync {
            service = boundService()
            assertEquals("Test must interrupt actual preparation, not a ready model", Phase.PREPARING, DictationBridge.state.value.phase)
            // Attempts during preload must not create a dictation session or target.
            repeat(3) { DictationBridge.start!!.invoke() }
            assertEquals(Phase.PREPARING, DictationBridge.state.value.phase)
            DictationBridge.disable?.invoke()
        }
        await("preload disable cleanup") {
            assertFalse("Disabling during preload must never record", recording())
            !DictationBridge.serviceRunning.value && !asrWorkerExists() && modelOwner() == null
        }
        assertEquals(Phase.OFF, DictationBridge.state.value.phase)
        assertNull("Loaded native resources must be released after constructor returns", modelOwner())
    }

    private fun startAndAwaitRecording(label: String) {
        val startedAt = SystemClock.elapsedRealtime()
        instrumentation.runOnMainSync { DictationBridge.start!!.invoke() }
        await("actual microphone active; state=${DictationBridge.state.value}", intervalMs = 5) {
            DictationBridge.state.value.phase == Phase.RECORDING && recording()
        }
        assertNotNull(modelOwner())
        metric("Warm request to confirmed microphone ($label): ${SystemClock.elapsedRealtime() - startedAt} ms; " +
            "native heap=${android.os.Debug.getNativeHeapAllocatedSize()} bytes; poll interval=5 ms")
        saveAppOps("recording-$label")
    }
    private fun boundService() = DictationBridge.start!!.javaClass.getMethod("getBoundReceiver")
        .invoke(DictationBridge.start) as DictationController
    private fun field(owner: Any, name: String): Any? = owner.javaClass.getDeclaredField(name)
        .apply { isAccessible = true }.get(owner)
    private fun modelOwner(): Any? = field(service, "recognizer")
    private fun nativeModel(owner: Any): Any? = field(owner, "recognizer")
    private fun metric(text: String) {
        File(context.getExternalFilesDir(null), "power-synthetic-metrics.txt").appendText("$text\n")
    }
    private fun saveAppOps(label: String) {
        File(context.getExternalFilesDir(null), "power-appops-$label.txt").writeText(shell("dumpsys appops ${context.packageName}"))
    }
    private fun assertIdle(label: String, owner: Any, native: Any) {
        assertEquals("State: ${DictationBridge.state.value}", Phase.READY, DictationBridge.state.value.phase)
        assertTrue("Warm idle must retain its parked ASR worker", asrWorkerExists())
        assertFalse("AudioRecord must be closed at $label", recording())
        assertSame("Idle must reuse recognizer owner", owner, modelOwner())
        assertSame("Idle must reuse actual native model", native, nativeModel(owner))
        assertNull("Idle must release per-utterance state and audio", field(owner, "session"))
        saveAppOps(label)
        metric("Warm idle $label: native heap=${android.os.Debug.getNativeHeapAllocatedSize()} bytes")
        assertForegroundType(false, label)
    }
    private fun recording() = context.getSystemService(AudioManager::class.java).activeRecordingConfigurations.isNotEmpty()
    private fun asrWorkerExists() = Thread.getAllStackTraces().keys.any { it.isAlive && it.name == "Floe-ASR" }
    private fun assertForegroundType(microphone: Boolean, label: String) {
        if (Build.VERSION.SDK_INT < 30) return
        val dump = shell("dumpsys activity services ${context.packageName}/.service.DictationService")
        File(context.getExternalFilesDir(null), "power-$label.txt").writeText(dump)
        var type = 0
        var active = false
        instrumentation.runOnMainSync {
            active = MicrophoneSession.service != null
            type = MicrophoneSession.service?.foregroundServiceType ?: 0
        }
        assertEquals("Microphone FGS instance at $label: $dump", microphone, active)
        assertEquals("Microphone FGS type at $label: $dump", microphone, type and 128 != 0)
        if (!microphone) {
            assertEquals(0, type)
            val manager = context.getSystemService(NotificationManager::class.java)
            val channel = manager.getNotificationChannel(FloeNotifications.STANDBY_CHANNEL)
            assertEquals("Standby must use MIN importance", NotificationManager.IMPORTANCE_MIN, channel.importance)
            val standby = manager.activeNotifications.singleOrNull { it.id == FloeNotifications.STANDBY_ID }
            assertNotNull("Standby drawer notification must remain present", standby)
            assertEquals("Standby must not be foreground", 0, standby!!.notification.flags and Notification.FLAG_FOREGROUND_SERVICE)
            assertFalse("Recording notification removed at idle", manager.activeNotifications.any { it.id == FloeNotifications.RECORDING_ID })
        }
    }
    private fun restoreSetting(key: String, value: String?) {
        if (value == null || value == "null" || value.isBlank()) shell("settings delete secure $key")
        else shell("settings put secure $key $value")
    }

    private fun await(description: String, intervalMs: Long = 50, condition: () -> Boolean) {
        val deadline = SystemClock.elapsedRealtime() + 120_000
        while (!condition() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(intervalMs)
        assertTrue("Timed out: $description; state=${DictationBridge.state.value}", condition())
    }
    private fun shell(command: String): String = instrumentation.getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES).executeShellCommand(command)
        .use { android.os.ParcelFileDescriptor.AutoCloseInputStream(it).bufferedReader().readText() }
}
