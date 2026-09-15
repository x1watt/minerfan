package app.minerfan

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridge between Dart and [MiningService] on the channel
 * `minerfan/service`.
 *
 * From Dart: `start` and `update` (with a `text` argument for the
 * notification), `stop`, `thermal`, `sustainedPerformance` (with `on`),
 * `sustainedPerformanceSupported`, `requestNotificationPermission`,
 * `batteryExempt` and `requestBatteryExemption`. To
 * Dart: `stopRequested` when the notification's Stop action is pressed.
 */
object MiningChannel {
    private const val NAME = "minerfan/service"
    private var channel: MethodChannel? = null
    var activity: Activity? = null

    /** Whether Dart asked for sustained performance mode (while mining). */
    private var sustained = false

    fun attach(engine: FlutterEngine, context: Context) {
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, NAME)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    MiningService.start(context, call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "update" -> {
                    MiningService.update(context, call.argument<String>("text") ?: "")
                    result.success(null)
                }
                "stop" -> {
                    MiningService.stop(context)
                    result.success(null)
                }
                "thermal" -> result.success(thermal(context))
                "sustainedPerformanceSupported" -> result.success(sustainedSupported(context))
                "sustainedPerformance" -> {
                    sustained = call.argument<Boolean>("on") ?: false
                    applySustained()
                    result.success(sustainedSupported(context))
                }
                "requestNotificationPermission" -> {
                    requestNotificationPermission()
                    result.success(null)
                }
                "batteryExempt" -> result.success(batteryExempt(context))
                "requestBatteryExemption" -> result.success(requestBatteryExemption(context))
                else -> result.notImplemented()
            }
        }
        channel = ch
    }

    /** Asks Dart to stop the node; Dart then calls `stop`. */
    fun requestStop(): Boolean {
        val ch = channel ?: return false
        ch.invokeMethod("stopRequested", null)
        return true
    }

    /**
     * Thermal status (API 29+), thermal headroom forecast for 10 s (API 30+;
     * 1.0 is where severe throttling starts) and battery temperature. Unknown
     * values are -1 (status, headroom) or NaN (battery).
     */
    private fun thermal(context: Context): Map<String, Any> {
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        val status = if (Build.VERSION.SDK_INT >= 29) pm.currentThermalStatus else -1
        var headroom = -1.0
        if (Build.VERSION.SDK_INT >= 30) {
            val h = pm.getThermalHeadroom(10)
            if (!h.isNaN()) headroom = h.toDouble()
        }
        val battery = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val tenths = battery?.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) ?: Int.MIN_VALUE
        val batteryC = if (tenths == Int.MIN_VALUE) Double.NaN else tenths / 10.0
        return mapOf("status" to status, "headroom" to headroom, "batteryC" to batteryC)
    }

    private fun sustainedSupported(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 24) return false
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isSustainedPerformanceModeSupported
    }

    /**
     * Sustained performance mode holds the CPU at clocks the device can keep
     * up indefinitely instead of bursting and then throttling. Android ties
     * it to a window, so it only applies while the app is on screen; each new
     * activity calls this again from onResume.
     */
    fun applySustained() {
        if (Build.VERSION.SDK_INT < 24) return
        val a = activity ?: return
        a.window?.setSustainedPerformanceMode(sustained)
    }

    /** Whether the app is exempt from battery optimization (Doze, app standby). */
    private fun batteryExempt(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < 23) return true
        val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Shows Android's dialog to exempt the app from battery optimization. With
     * it, the system and vendor battery managers leave the miner alone more
     * often, and the watchdog may restart mining from the background.
     * Returns false when there is no activity to show it from.
     */
    @SuppressLint("BatteryLife") // the app is not distributed on Google Play
    private fun requestBatteryExemption(context: Context): Boolean {
        if (batteryExempt(context)) return true
        val a = activity ?: return false
        return try {
            a.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS, Uri.parse("package:${context.packageName}")),
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Android 13 and later show the mining notification only with this permission. */
    private fun requestNotificationPermission() {
        val a = activity ?: return
        if (Build.VERSION.SDK_INT < 33) return
        if (a.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) return
        a.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
    }
}
