package com.sonicwave.sonic_wave

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.app.ServiceCompat
import io.flutter.plugin.common.MethodChannel

/**
 * Keeps a download alive while the app is in the background, and shows its
 * progress.
 *
 * A link shared from another app is the download most likely to be fired off and
 * abandoned: the user was in YouTube, not here. Without a foreground service the
 * process is an ordinary background app the moment they switch away, so Android
 * may reclaim it mid-transfer — the download dies and the file never appears,
 * with nothing on screen to say so. `dataSync` is the type that covers exactly
 * this: a bounded transfer the user asked for.
 *
 * Notification progress and the Cancel action are the visible half. Cancel comes
 * back through [channel] so it runs the same cancel path as the in-app button,
 * rather than a second way to stop a download that could drift from it.
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "sonicwave_downloads"
        private const val NOTIFICATION_ID = 4711

        const val ACTION_START = "com.sonicwave.sonic_wave.download.START"
        const val ACTION_UPDATE = "com.sonicwave.sonic_wave.download.UPDATE"
        const val ACTION_COMPLETE = "com.sonicwave.sonic_wave.download.COMPLETE"
        const val ACTION_FAIL = "com.sonicwave.sonic_wave.download.FAIL"
        const val ACTION_STOP = "com.sonicwave.sonic_wave.download.STOP"
        const val ACTION_CANCEL = "com.sonicwave.sonic_wave.download.CANCEL"

        const val EXTRA_VIDEO_ID = "videoId"
        const val EXTRA_TITLE = "title"
        const val EXTRA_SUBTITLE = "subtitle"
        const val EXTRA_PERCENT = "percent"
        const val EXTRA_REASON = "reason"

        /**
         * Set by MainActivity while a Flutter engine exists. Null once the engine
         * is gone, which is why every use is null-checked: a Cancel tap can
         * outlive the UI, and the service still has to stop itself.
         */
        var channel: MethodChannel? = null

        fun start(context: Context, videoId: String, title: String, subtitle: String) {
            val intent = Intent(context, DownloadForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_VIDEO_ID, videoId)
                putExtra(EXTRA_TITLE, title)
                putExtra(EXTRA_SUBTITLE, subtitle)
            }
            // startForegroundService: this is called while the app is still
            // foregrounded, and startForeground() follows immediately in
            // onStartCommand, well inside the 5s the platform allows.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun send(context: Context, action: String, extras: Intent.() -> Unit = {}) {
            val intent = Intent(context, DownloadForegroundService::class.java).apply {
                this.action = action
                extras()
            }
            context.startService(intent)
        }
    }

    private var currentVideoId: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                currentVideoId = intent.getStringExtra(EXTRA_VIDEO_ID)
                val notification = buildProgress(
                    title = intent.getStringExtra(EXTRA_TITLE) ?: "Downloading",
                    subtitle = intent.getStringExtra(EXTRA_SUBTITLE) ?: "",
                    percent = -1,
                )
                startForegroundCompat(notification)
            }

            ACTION_UPDATE -> {
                intent.getStringExtra(EXTRA_VIDEO_ID)?.let { currentVideoId = it }
                notify(
                    buildProgress(
                        title = intent.getStringExtra(EXTRA_TITLE) ?: "Downloading",
                        subtitle = intent.getStringExtra(EXTRA_SUBTITLE) ?: "",
                        percent = intent.getIntExtra(EXTRA_PERCENT, -1),
                    )
                )
            }

            ACTION_COMPLETE -> {
                // Leave the notification behind, dismissible: the result is the
                // reason the user shared the link, and they may not be watching.
                notify(
                    buildTerminal(
                        title = "Saved to Downloads",
                        body = intent.getStringExtra(EXTRA_TITLE) ?: "",
                    )
                )
                detachKeepingNotification()
            }

            ACTION_FAIL -> {
                val reason = intent.getStringExtra(EXTRA_REASON).orEmpty()
                notify(
                    buildTerminal(
                        title = "Download failed",
                        body = listOf(intent.getStringExtra(EXTRA_TITLE).orEmpty(), reason)
                            .filter { it.isNotBlank() }
                            .joinToString(" · "),
                    )
                )
                detachKeepingNotification()
            }

            ACTION_CANCEL -> {
                // Route the tap through Dart so it runs the ordinary cancel path
                // (task cancel, partial-file cleanup, card dismissal).
                currentVideoId?.let { channel?.invokeMethod("onDownloadCancelRequested", it) }
                stopEverything()
            }

            ACTION_STOP -> stopEverything()
        }
        // The work lives in the Dart isolate, not here — there is nothing to
        // resume if the service is recreated after being killed.
        return START_NOT_STICKY
    }

    private fun startForegroundCompat(notification: Notification) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceCompat.startForeground(
                    this,
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            // A denied POST_NOTIFICATIONS grant, or a background-start
            // restriction. The download continues in Dart either way, so this
            // must never take the app down.
            stopSelf()
        }
    }

    private fun notify(notification: Notification) {
        try {
            NotificationManagerCompat.from(this).notify(NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS not granted — nothing to show, nothing to fix.
        }
    }

    /** Drop the foreground obligation but leave the terminal notification up. */
    private fun detachKeepingNotification() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_DETACH)
        currentVideoId = null
        stopSelf()
    }

    private fun stopEverything() {
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        currentVideoId = null
        stopSelf()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        // LOW: a download the user started needs to be visible, not announced.
        // IMPORTANCE_DEFAULT would buzz for every share.
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Downloads",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Progress for songs being saved for offline playback"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun baseBuilder(): NotificationCompat.Builder =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(contentIntent())
            .setSilent(true)

    private fun buildProgress(title: String, subtitle: String, percent: Int): Notification {
        val builder = baseBuilder()
            .setContentTitle(title)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(
                android.R.drawable.ic_menu_close_clear_cancel,
                "Cancel",
                cancelIntent(),
            )
        if (subtitle.isNotBlank()) builder.setContentText(subtitle)
        if (percent < 0) {
            // Resolving the video's details — there is no fraction to show yet,
            // and a bar sitting at 0% reads as a stalled download.
            builder.setProgress(0, 0, true)
            builder.setSubText("Preparing")
        } else {
            builder.setProgress(100, percent, false)
            builder.setSubText("$percent%")
        }
        return builder.build()
    }

    private fun buildTerminal(title: String, body: String): Notification {
        val builder = baseBuilder()
            .setContentTitle(title)
            .setOngoing(false)
            .setAutoCancel(true)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
        if (body.isNotBlank()) builder.setContentText(body)
        return builder.build()
    }

    /** Tapping the notification opens the app. */
    private fun contentIntent(): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        return PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun cancelIntent(): PendingIntent {
        val intent = Intent(this, DownloadForegroundService::class.java).apply {
            action = ACTION_CANCEL
        }
        return PendingIntent.getService(
            this,
            1,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }
}
