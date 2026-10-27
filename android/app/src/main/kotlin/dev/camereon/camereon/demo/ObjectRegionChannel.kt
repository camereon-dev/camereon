package dev.camereon.camereon.demo

import android.app.Activity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal class ObjectRegionChannel(private val activity: Activity, engine: FlutterEngine) {
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.camereon/object_regions")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "detect") result.notImplemented()
            else {
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null || closed.get() || !busy.compareAndSet(false, true)) {
                    result.error("unavailable", "人物・画面候補を検出できませんでした", null)
                } else executor.execute {
                    try {
                        val detection = ObjectRegionDetector(activity.assets).detect(bytes)
                        activity.runOnUiThread { if (!closed.get()) result.success(detection) }
                    } catch (_: Exception) {
                        activity.runOnUiThread {
                            if (!closed.get()) result.error("failed", "人物・画面候補を検出できませんでした", null)
                        }
                    } finally { busy.set(false) }
                }
            }
        }
    }

    fun close() {
        closed.set(true)
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }
}
