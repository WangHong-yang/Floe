package com.floe.android.service

import android.content.*
import android.os.Build
import com.floe.android.asr.OfflineRecognizer
import com.floe.android.core.*
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

class DictationController(private val context: Context, private val operations: Mutex, private val onFailure: () -> Unit) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var recognizer: OfflineRecognizer? = null
    private val captureIntent = CaptureIntent()
    private var activeSessionId = 0L
    private var sessionTarget: InsertionTarget? = null
    private var destroyed = false
    private var enabled = false
    private var receiverRegistered = false
    private var microphoneTicket: MicrophoneSession.Ticket? = null
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) { if (intent?.action == Intent.ACTION_SCREEN_OFF) cancelCapture() }
    }
    fun enable() {
        check(!destroyed) { "Controller already closed" }
        if (enabled) return
        enabled = true
        DictationBridge.serviceRunning.value = true
        FloeNotifications.createChannels(context)
        DictationBridge.start = ::startCapture; DictationBridge.finish = ::finishCapture; DictationBridge.cancel = ::cancelCapture
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF)
        if (Build.VERSION.SDK_INT >= 33) context.registerReceiver(screenReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        else context.registerReceiver(screenReceiver, filter)
        receiverRegistered = true
        updateNotification(false)
        prepareModel()
    }
    private fun prepareModel() {
        // Allocate once per enabled service. READY means the model is already in memory.
        val engine = OfflineRecognizer(context)
        recognizer = engine
        DictationBridge.update(DictationState(Phase.PREPARING,
            message = "Preparing offline speech once. The microphone is off…"))
        scope.launch { operations.withLock {
            if (destroyed || recognizer !== engine) return@withLock
            try {
                engine.prepare()
                if (!destroyed && recognizer === engine) {
                    DictationBridge.update(DictationState(Phase.READY,
                        message = "Ready. The offline model stays loaded while Floe is on. Microphone off."))
                }
            } catch (error: Throwable) {
                if (!destroyed) {
                    fail("Could not prepare offline speech: ${error.message ?: error.javaClass.simpleName}. Enable Floe again.")
                    onFailure()
                }
            }
        } }
    }
    private fun startCapture() {
        if (destroyed || DictationBridge.state.value.phase != Phase.READY) return
        val target = DictationBridge.target
        if (target == null || !runCatching { target.begin() }.getOrDefault(false)) { DictationBridge.update(DictationBridge.state.value.copy(message = "Select a non-password text field first.")); return }
        val id = captureIntent.begin() ?: run { runCatching { target.cancel() }; return }
        activeSessionId = id
        sessionTarget = target
        DictationBridge.update(DictationState(Phase.LOADING, message = "Starting the microphone…"))
        scope.launch { operations.withLock {
            if (destroyed || !captureIntent.isCurrent(id)) return@withLock
            try {
                val engine = checkNotNull(recognizer) { "The offline model is not ready" }
                // Finish/cancel/screen-off can invalidate this request before capture starts.
                if (destroyed || !captureIntent.loaded(id)) return@withLock
                val ticket = MicrophoneSession.request(context) { if (!destroyed && captureIntent.isCurrent(id)) cancelCapture("Microphone service stopped.") }
                microphoneTicket = ticket
                FloeNotifications.hideStandby(context)
                withTimeout(5000) { ticket.ready.await() }
                if (destroyed || !captureIntent.isCurrent(id)) return@withLock
                engine.start(
                    onPartial = { text -> if (!destroyed && captureIntent.isCurrent(id) && captureIntent.stage == CaptureIntent.Stage.RECORDING) {
                        try {
                            sessionTarget?.partial(text)
                            DictationBridge.update(DictationState(Phase.RECORDING, text, "Listening…"))
                        } catch (error: Throwable) { abortWithError(error) }
                    } },
                    onError = { error -> if (!destroyed && captureIntent.isCurrent(id)) abortWithError(error) },
                    onStarted = { if (!destroyed && captureIntent.isCurrent(id) && captureIntent.stage == CaptureIntent.Stage.RECORDING) {
                        DictationBridge.update(DictationState(Phase.RECORDING, message = "Listening…")); updateNotification(true)
                    } },
                    onStopped = {
                        // Cleanup is tied to the exact ticket, even while this owner closes.
                        // An old session can never remove a newer microphone foreground service.
                        if (microphoneTicket === ticket) {
                            try {
                                MicrophoneSession.release(context, ticket)
                                microphoneTicket = null
                                if (!destroyed) updateNotification(false)
                            } catch (_: RuntimeException) {
                                if (!destroyed) {
                                    fail("Floe could not return to idle. Enable Floe again.")
                                    onFailure()
                                }
                            }
                        }
                    },
                )
            } catch (error: Throwable) { if (!destroyed && captureIntent.isCurrent(id)) abortWithError(error) }
        } }
    }
    private fun finishCapture() {
        if (destroyed) return
        if (DictationBridge.state.value.phase == Phase.LOADING) {
            cancelCapture("Stopped before recording began. Wait for “Listening” before speaking.")
            return
        }
        if (!captureIntent.finish()) return
        val id = activeSessionId
        DictationBridge.update(DictationBridge.state.value.copy(phase = Phase.FINISHING, message = "Finishing…"))
        val engine = recognizer ?: return
        // Stop capture immediately, even if another lifecycle operation holds the mutex.
        engine.requestFinish()
        scope.launch { operations.withLock {
            if (recognizer !== engine || destroyed || !captureIntent.isCurrent(id)) return@withLock
            try {
                val text = engine.finish().trim()
                if (!destroyed) setForegroundMicrophone(false)
                if (destroyed || !captureIntent.isCurrent(id) || sessionTarget == null) return@withLock
                val message = if (text.isBlank()) { sessionTarget?.cancel(); "No speech detected. Please try again." }
                    else sessionTarget?.finish(text) ?: "Text kept. Open Floe to copy it."
                sessionTarget = null
                // AudioRecord and the utterance stream are gone; the model remains warm.
                captureIntent.released(id)
                DictationBridge.update(DictationState(Phase.READY, text, message)); updateNotification(false)
            } catch (error: Throwable) { if (!destroyed && captureIntent.isCurrent(id) && sessionTarget != null) abortWithError(error) }
        } }
    }
    private fun cancelCapture() = cancelCapture("Recording cancelled.")
    private fun cancelCapture(message: String) {
        if (destroyed) return
        if (DictationBridge.state.value.phase !in setOf(Phase.LOADING, Phase.RECORDING, Phase.FINISHING)) return
        resetCapture(message)
    }
    private fun abortWithError(error: Throwable) {
        resetCapture("Recording failed: ${error.message ?: error.javaClass.simpleName}. Please try again.")
    }
    private fun resetCapture(message: String) {
        if (destroyed) return
        val id = captureIntent.cancel()
        recognizer?.requestCancel(); microphoneTicket?.ready?.cancel(); cancelTarget()
        DictationBridge.update(DictationState(Phase.FINISHING, message = "Stopping recording…"))
        scope.launch { operations.withLock {
            try {
                // cancel waits for AudioRecord and OnlineStream, then clears only this session.
                recognizer?.cancel()
                if (!destroyed) setForegroundMicrophone(false)
                if (!destroyed && captureIntent.released(id)) {
                    DictationBridge.update(DictationState(Phase.READY, message = message))
                    updateNotification(false)
                }
            } catch (error: Throwable) {
                android.util.Log.e("FloeLifecycle", "Recording cleanup failed", error)
                if (!destroyed) {
                    fail("Could not stop recording cleanly. Enable Floe again.")
                    onFailure()
                }
            }
        } }
    }
    private fun cancelTarget() {
        val target = sessionTarget
        sessionTarget = null
        // A stale editor must never prevent microphone/model cleanup.
        runCatching { target?.cancel() }
    }
    private suspend fun releaseRecognizer() {
        val engine = recognizer
        try { engine?.close() }
        finally {
            if (recognizer === engine) recognizer = null
            setForegroundMicrophone(false)
        }
    }
    private fun fail(message: String) { DictationBridge.update(DictationState(Phase.ERROR, message = message)) }
    fun close() {
        if (destroyed) return
        destroyed = true; DictationBridge.serviceRunning.value = false
        if (receiverRegistered) { context.unregisterReceiver(screenReceiver); receiverRegistered = false }
        captureIntent.cancel(); recognizer?.requestClose(); microphoneTicket?.ready?.cancel(); cancelTarget()
        DictationBridge.start = null; DictationBridge.finish = null; DictationBridge.cancel = null
        if (DictationBridge.state.value.phase != Phase.ERROR) DictationBridge.update(DictationState())
        scope.launch {
            try { operations.withLock { releaseRecognizer() } }
            catch (_: Throwable) { /* Service is already stopped; close still releases its worker. */ }
            finally { scope.cancel() }
        }
        FloeNotifications.hideStandby(context)
    }
    private fun setForegroundMicrophone(active: Boolean) {
        check(!active) { "Recording foreground service must complete its ready handshake first" }
        microphoneTicket?.let { MicrophoneSession.release(context, it) }
        microphoneTicket = null
        if (!destroyed) updateNotification(false)
    }
    private fun updateNotification(recording: Boolean) {
        if (!destroyed) {
            if (recording) FloeNotifications.hideStandby(context)
            else FloeNotifications.showStandby(context)
        }
    }
}
