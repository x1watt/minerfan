package app.minerfan

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
import android.os.PowerManager

/**
 * Foreground service held while the node runs. It keeps the process alive
 * when the app is closed, holds a partial wake lock so the CPU keeps mining
 * with the screen off, and shows a notification with the hashrate and a Stop
 * action. The mining itself runs in Dart (the node isolate and its workers).
 */
class MiningService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            // Let Dart stop the node and save its state; it then stops us.
            MiningWatchdog.cancel(this)
            if (!MiningChannel.requestStop()) stopSelf()
            return START_NOT_STICKY
        }
        // A null intent is Android restarting this sticky service after it
        // killed the process; RESUME comes from the watchdog or after a boot.
        val resuming = intent == null || intent.action == ACTION_RESUME
        if (resuming && !MinerEngine.miningWanted(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        val text = if (resuming) "Resuming mining" else intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val notification = buildNotification(this, text)
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        running = true
        acquireWakeLock()
        MiningWatchdog.schedule(this)
        // Starts Dart if the process is new; with the master switch on it
        // resumes mining by itself.
        if (resuming) MinerEngine.ensure(this)
        return START_STICKY
    }

    @Suppress("WakelockTimeout") // held exactly as long as the user mines
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "minerfan:mining").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        running = false
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "mining"
        private const val NOTIFICATION_ID = 1
        private const val EXTRA_TEXT = "text"
        private const val ACTION_STOP = "app.minerfan.STOP"
        private const val ACTION_RESUME = "app.minerfan.RESUME"
        @Volatile private var running = false

        val isRunning: Boolean get() = running

        /** Starts the service to resume mining (watchdog, boot, update). */
        fun resume(context: Context, why: String) {
            val intent = Intent(context, MiningService::class.java).setAction(ACTION_RESUME).putExtra("why", why)
            try {
                if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
            } catch (e: Exception) {
                // Android 12+ refuses background starts unless the app is
                // exempt from battery optimization; the next chance is the
                // next watchdog run or the user opening the app.
            }
        }

        fun start(context: Context, text: String) {
            val intent = Intent(context, MiningService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) context.startForegroundService(intent) else context.startService(intent)
        }

        fun update(context: Context, text: String) {
            if (!running) return
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIFICATION_ID, buildNotification(context, text))
        }

        fun stop(context: Context) {
            MiningWatchdog.cancel(context)
            context.stopService(Intent(context, MiningService::class.java))
        }

        @Suppress("DEPRECATION")
        private fun buildNotification(context: Context, text: String): Notification {
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            val open = PendingIntent.getActivity(
                context, 0,
                Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags,
            )
            val stop = PendingIntent.getService(
                context, 1,
                Intent(context, MiningService::class.java).setAction(ACTION_STOP), flags,
            )
            val builder = if (Build.VERSION.SDK_INT >= 26) {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                    nm.createNotificationChannel(
                        NotificationChannel(CHANNEL_ID, "Mining", NotificationManager.IMPORTANCE_LOW).apply {
                            description = "Shows while the miner runs"
                        },
                    )
                }
                Notification.Builder(context, CHANNEL_ID)
            } else {
                Notification.Builder(context)
            }
            builder
                .setSmallIcon(R.drawable.ic_stat_mining)
                .setContentTitle("minerfan")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(open)
                .addAction(0, "Stop", stop)
            if (Build.VERSION.SDK_INT >= 31) {
                builder.setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
            }
            return builder.build()
        }
    }
}
