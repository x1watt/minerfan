package app.minerfan

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent

/**
 * Every 15 minutes (the shortest period Android allows), and across
 * reboots: if the master switch is on but the mining service is gone
 * (the system or a vendor battery manager killed the process and did not
 * restart it), start it again. Android lets the app start its foreground
 * service from the background while it is exempt from battery
 * optimization, which the app asks for when mining first starts.
 */
class MiningWatchdog : JobService() {
    override fun onStartJob(params: JobParameters?): Boolean {
        if (!MinerEngine.miningWanted(this)) {
            cancel(this)
        } else if (!MiningService.isRunning) {
            MiningService.resume(this, "watchdog")
        }
        return false
    }

    override fun onStopJob(params: JobParameters?): Boolean = false

    companion object {
        private const val JOB_ID = 7101

        fun schedule(context: Context) {
            val js = context.getSystemService(JobScheduler::class.java) ?: return
            if (js.getPendingJob(JOB_ID) != null) return
            val job = JobInfo.Builder(JOB_ID, ComponentName(context, MiningWatchdog::class.java))
                .setPeriodic(15 * 60 * 1000L)
                .setPersisted(true)
                .build()
            js.schedule(job)
        }

        fun cancel(context: Context) {
            context.getSystemService(JobScheduler::class.java)?.cancel(JOB_ID)
        }
    }
}

/** After a reboot or an app update: resume mining if the master switch was on. */
class MiningBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                if (MinerEngine.miningWanted(context)) MiningService.resume(context, intent.action ?: "boot")
        }
    }
}
