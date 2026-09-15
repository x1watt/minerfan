package app.minerfan

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import org.json.JSONObject
import java.io.File

/**
 * The process-wide Flutter engine that runs the Dart app (and with it the
 * miners). The activity attaches to it; after the system killed the process,
 * [MiningService] starts it without any activity, and Dart resumes mining on
 * its own when the master switch was on.
 */
object MinerEngine {
    const val ENGINE_ID = "minerfan"

    fun ensure(context: Context): FlutterEngine {
        val cache = FlutterEngineCache.getInstance()
        cache.get(ENGINE_ID)?.let { return it }
        val app = context.applicationContext
        val engine = FlutterEngine(app)
        MiningChannel.attach(engine, app)
        // Runs main(); an activity that attaches later sees Dart running and
        // does not start it again.
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        cache.put(ENGINE_ID, engine)
        return engine
    }

    /** The master switch as Dart saved it (`files/minerfan/app.json`). */
    fun miningWanted(context: Context): Boolean = try {
        JSONObject(File(context.filesDir, "minerfan/app.json").readText()).optBoolean("miningOn", false)
    } catch (e: Exception) {
        false
    }
}
