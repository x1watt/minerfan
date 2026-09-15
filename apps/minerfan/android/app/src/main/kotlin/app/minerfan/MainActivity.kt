package app.minerfan

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The Flutter engine, and with it the Dart node and the mining threads, lives
 * as long as the process, not as long as this activity. While mining,
 * [MiningService] keeps the process alive, so closing the app does not stop
 * the node, and reopening it attaches to the same running engine. After the
 * system killed the process, [MiningService] starts the engine without this
 * activity ([MinerEngine]) so mining resumes with the app closed.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine = MinerEngine.ensure(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MiningChannel.activity = this
    }

    override fun onResume() {
        super.onResume()
        MiningChannel.activity = this
        MiningChannel.applySustained()
    }

    override fun onDestroy() {
        if (MiningChannel.activity === this) MiningChannel.activity = null
        super.onDestroy()
    }

    companion object {
        const val ENGINE_ID = MinerEngine.ENGINE_ID
    }
}
