package dev.camereon.camereon.demo

import android.content.res.AssetManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Rect
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.FloatBuffer
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Offline object regions; no VLM, OCR strings, networking or image logs.
 * Vehicles are offered for their number plates; distant specks are omitted.
 */
internal class ObjectRegionDetector(private val assets: AssetManager) {
    private data class Box(val classId: Int, val score: Float,
                           val left: Double, val top: Double,
                           val right: Double, val bottom: Double) {
        val area: Double get() = (right - left) * (bottom - top)
        /** True when this lower-scored box adds nothing to an already kept one. */
        fun redundantWith(kept: Box): Boolean {
            // A car also scored as a truck is one vehicle, not two candidates.
            if (kind(classId) != kind(kept.classId)) return false
            val intersection = max(0.0, min(right, kept.right) - max(left, kept.left)) *
                max(0.0, min(bottom, kept.bottom) - max(top, kept.top))
            if (intersection / (area + kept.area - intersection) > .7) return true
            // Vehicles rarely nest; a partial body inside a kept vehicle is the
            // same vehicle. People and screens may legitimately overlap.
            return kind(classId) == "vehicle" && intersection >= area * .8
        }
    }

    fun detect(pixels: ByteArray, width: Int, height: Int,
               tuning: OnnxSessions.Tuning = OnnxSessions.Tuning()): Map<String, Any> {
        require(width in 1..1600 && height in 1..1600 && pixels.size == width * height * 4)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))
        val start = System.nanoTime()
        try {
            val spec = assets.open("object_detection/model.json").use {
                JSONObject(it.bufferedReader().readText())
            }
            val environment = OnnxSessions.environment
            // The shared session verifies the manifest's SHA-256 before first use.
            val all = OnnxSessions.use(assets, "object_detection/" + spec.getString("file"),
                spec.getString("sha256"), tuning) { session ->
                // Both sizes matter: the 640px pass recovers the crouched
                // person in the evaluation, while 1280px finds small screens.
                listOf(640, 1280).flatMap { infer(bitmap, it, session, environment) }
            }
            val selected = mutableListOf<Box>()
            val minimumVehicleSide = max(bitmap.width, bitmap.height) * .06
            for (box in all.sortedByDescending { it.score }) {
                if (kind(box.classId) == "vehicle" &&
                    max(box.right - box.left, box.bottom - box.top) < minimumVehicleSide) continue
                if (selected.none { box.redundantWith(it) }) selected.add(box)
            }
            val ordered = selected.sortedWith(compareBy({ it.top }, { it.left }))
            return mapOf("width" to bitmap.width, "height" to bitmap.height,
                "candidates" to ordered.take(200).map { box ->
                    mapOf("kind" to kind(box.classId),
                        "box" to listOf(box.left, box.top, box.right, box.bottom))
                }, "truncated" to (ordered.size > 200),
                "elapsedMs" to (System.nanoTime() - start) / 1_000_000.0)
        } finally { bitmap.recycle() }
    }

    private fun infer(bitmap: Bitmap, size: Int, session: OrtSession,
                      environment: OrtEnvironment): List<Box> {
        val scale = min(size.toDouble() / bitmap.width, size.toDouble() / bitmap.height)
        val rw = (bitmap.width * scale).roundToInt().coerceAtLeast(1)
        val rh = (bitmap.height * scale).roundToInt().coerceAtLeast(1)
        val padWidth = (size - rw) % 32
        val padHeight = (size - rh) % 32
        val width = rw + padWidth; val height = rh + padHeight
        val leftPad = ((padWidth / 2.0) - .1).roundToInt()
        val topPad = ((padHeight / 2.0) - .1).roundToInt()
        val resized = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val pixels = IntArray(width * height)
        try {
            Canvas(resized).apply {
                drawColor(Color.rgb(114, 114, 114))
                drawBitmap(bitmap, null, Rect(leftPad, topPad, leftPad + rw, topPad + rh),
                    Paint(Paint.FILTER_BITMAP_FLAG))
            }
            resized.getPixels(pixels, 0, width, 0, 0, width, height)
        } finally { resized.recycle() }
        val plane = width * height
        val input = FloatArray(plane * 3)
        for (i in pixels.indices) {
            input[i] = ((pixels[i] ushr 16) and 255) / 255f
            input[plane + i] = ((pixels[i] ushr 8) and 255) / 255f
            input[plane * 2 + i] = (pixels[i] and 255) / 255f
        }
        return OnnxTensor.createTensor(environment, FloatBuffer.wrap(input),
            longArrayOf(1, 3, height.toLong(), width.toLong())).use { tensor ->
            OnnxSessions.run(session, mapOf(session.inputNames.first() to tensor)) { output ->
                val result = output[0] as OnnxTensor
                val shape = result.info.shape
                check(shape.size == 3 && shape[0] == 1L && shape[2] == 6L && shape[1] <= 300)
                val buffer = result.floatBuffer
                val found = mutableListOf<Box>()
                repeat(shape[1].toInt()) {
                    val x1 = buffer.get(); val y1 = buffer.get()
                    val x2 = buffer.get(); val y2 = buffer.get()
                    val score = buffer.get(); val label = buffer.get()
                    if (listOf(x1, y1, x2, y2, score, label).all { it.isFinite() } &&
                        score >= .25f && label in CLASSES) {
                        val l = ((x1 - leftPad) / scale).coerceIn(0.0, bitmap.width.toDouble())
                        val t = ((y1 - topPad) / scale).coerceIn(0.0, bitmap.height.toDouble())
                        val r = ((x2 - leftPad) / scale).coerceIn(0.0, bitmap.width.toDouble())
                        val b = ((y2 - topPad) / scale).coerceIn(0.0, bitmap.height.toDouble())
                        if (l < r && t < b) found.add(Box(label.toInt(), score, l, t, r, b))
                    }
                }
                found
            }
        }
    }

    companion object {
        // COCO: person, car, motorcycle, bus, truck, tv, laptop, cell phone.
        val CLASSES = listOf(0f, 2f, 3f, 5f, 7f, 62f, 63f, 67f)

        fun kind(classId: Int) = when (classId) {
            0 -> "person"
            2, 3, 5, 7 -> "vehicle"
            else -> "screen"
        }
    }
}
