package dev.camereon.camereon.demo

import android.app.Activity
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

internal class TextRegionChannel(private val activity: Activity, engine: FlutterEngine) {
    private val executor = Executors.newSingleThreadExecutor()
    private val busy = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.camereon/text_regions")

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "release") {
                // Housekeeping: drop cached detector sessions (both models) now.
                OnnxSessions.release()
                result.success(null)
            } else if (call.method != "detect") {
                result.notImplemented()
            } else {
                val bytes = call.argument<ByteArray>("bytes")
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                val detailed = call.argument<Boolean>("detailed") ?: true
                val tuning = tuning(call.argument<Map<String, Any>>("tuning"))
                if (bytes == null || closed.get() || !busy.compareAndSet(false, true)) {
                    result.error("unavailable", "文字候補を検出できませんでした", null)
                } else {
                    executor.execute {
                        try {
                            val detection = TextRegionDetector(activity.assets)
                                .detect(bytes, width, height, detailed, tuning)
                            activity.runOnUiThread { if (!closed.get()) result.success(detection) }
                        } catch (error: Throwable) {
                            // Only the exception class leaves the process: no message, no image data.
                            Log.w("camereon", "text detection failed: " + error.javaClass.simpleName)
                            // Includes OutOfMemoryError on large photos: report, never crash.
                            // Never log image contents or native exception payloads.
                            activity.runOnUiThread {
                                if (!closed.get()) result.error("failed", "文字候補を検出できませんでした", null)
                            }
                        } finally { busy.set(false) }
                    }
                }
            }
        }
    }

    fun close() {
        closed.set(true)
        channel.setMethodCallHandler(null)
        executor.shutdown()
    }

    companion object {
        /** Measurement-only override; production calls omit the map. */
        fun tuning(map: Map<String, Any>?): OnnxSessions.Tuning {
            val threads = (map?.get("threads") as? Number)?.toInt() ?: return OnnxSessions.Tuning()
            return OnnxSessions.Tuning(threads = threads.coerceIn(1, 8))
        }
    }
}
