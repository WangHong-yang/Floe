package com.floe.android.service

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.floe.android.MainActivity
import com.floe.android.R
import com.floe.android.core.DictationBridge

internal object FloeNotifications {
    const val STANDBY_ID = 1001
    const val RECORDING_ID = 1002
    // A new ID is essential: Android preserves the old channel's LOW importance.
    const val STANDBY_CHANNEL = "floe_standby_v2"
    const val RECORDING_CHANNEL = "floe_recording"
    fun createChannels(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(STANDBY_CHANNEL, "Floe standby", NotificationManager.IMPORTANCE_MIN).apply {
            description = "Silent drawer notification while Floe is enabled. Microphone off."
            setSound(null, null); enableVibration(false); setShowBadge(false)
        })
        manager.createNotificationChannel(NotificationChannel(RECORDING_CHANNEL, "Floe recording", NotificationManager.IMPORTANCE_LOW).apply {
            setSound(null, null); enableVibration(false); setShowBadge(false)
        })
    }
    private fun notification(context: Context, recording: Boolean): Notification {
        val open = PendingIntent.getActivity(context, 0, Intent(context, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val disable = PendingIntent.getBroadcast(context, 1, Intent(context, DisableFloeReceiver::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        return Notification.Builder(context, if (recording) RECORDING_CHANNEL else STANDBY_CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (recording) "Floe is recording" else "Floe is enabled")
            .setContentText(if (recording) "Release or tap the tick to finish." else "Microphone off. Tap to open Floe.")
            .setContentIntent(open).setOngoing(true).setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Disable Floe", disable).build()).build()
    }
    fun showStandby(context: Context) {
        if (Build.VERSION.SDK_INT >= 33 && context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) return
        context.getSystemService(NotificationManager::class.java).notify(STANDBY_ID, notification(context, false))
    }
    fun hideStandby(context: Context) {
        context.getSystemService(NotificationManager::class.java).cancel(STANDBY_ID)
    }
    fun recording(context: Context): Notification = notification(context, true)
}

/** Does not start a service, even if a stale notification action arrives after teardown. */
class DisableFloeReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) { DictationBridge.disable?.invoke() }
}
