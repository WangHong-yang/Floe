package com.floe.android.service

import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import kotlinx.coroutines.CompletableDeferred
import java.util.concurrent.atomic.AtomicLong

/**
 * A short-lived microphone foreground service. The system-bound AccessibilityService
 * owns the model; only a user recording gesture requests this service. Android 14+
 * permits the system-bound accessibility service to start a microphone FGS. If an
 * OEM denies this exemption, fail closed instead of opening AudioRecord without it.
 */
class DictationService : Service() {
    private var token = 0L
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requested = intent?.getLongExtra(EXTRA_TOKEN, 0L) ?: 0L
        val ticket = MicrophoneSession.current
        if (ticket == null || ticket.token != requested || ticket.ready.isCancelled) {
            if (ticket == null || token != ticket.token) stopSelf(startId)
            return START_NOT_STICKY
        }
        token = requested
        try {
            FloeNotifications.createChannels(this)
            val notification = FloeNotifications.recording(this)
            if (Build.VERSION.SDK_INT >= 30) {
                startForeground(FloeNotifications.RECORDING_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            } else {
                startForeground(FloeNotifications.RECORDING_ID, notification)
            }
            MicrophoneSession.service = this
            ticket.ready.complete(Unit)
        } catch (error: RuntimeException) {
            ticket.ready.completeExceptionally(error)
            stopSelf(startId)
        }
        return START_NOT_STICKY
    }

    internal fun release() {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onDestroy() {
        if (MicrophoneSession.service === this) MicrophoneSession.service = null
        val current = MicrophoneSession.current
        if (current?.token == token) {
            MicrophoneSession.current = null
            current.ready.completeExceptionally(IllegalStateException("Microphone service stopped"))
            current.onLost()
        }
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
    companion object { const val EXTRA_TOKEN = "session_token" }
}

/** Main-thread-only broker. Unique tokens prevent delayed service starts from reviving old captures. */
internal object MicrophoneSession {
    private val sequence = AtomicLong()
    class Ticket(val token: Long, val onLost: () -> Unit) {
        val ready = CompletableDeferred<Unit>()
    }
    var current: Ticket? = null
    var service: DictationService? = null

    fun request(context: Context, onLost: () -> Unit): Ticket {
        check(current == null) { "A microphone session is still stopping" }
        val ticket = Ticket(sequence.incrementAndGet(), onLost)
        current = ticket
        try {
            context.startForegroundService(Intent(context, DictationService::class.java)
                .putExtra(DictationService.EXTRA_TOKEN, ticket.token))
        } catch (error: RuntimeException) {
            current = null
            throw error
        }
        return ticket
    }

    fun release(context: Context, ticket: Ticket) {
        if (current !== ticket) return
        current = null
        ticket.ready.cancel()
        val running = service
        service = null
        if (running != null) running.release()
        else context.stopService(Intent(context, DictationService::class.java))
    }
}
