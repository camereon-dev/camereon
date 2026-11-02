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
import kotlin.math.ceil
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Offline object regions; no VLM, OCR strings, networking or image logs.
 * The segmentation model also yields a silhouette mask per kept box, so
 * people, screens and vehicles can be hidden along their outline.
 * Vehicles are offered for their number plates; distant specks are omitted.
 */
internal class ObjectRegionDetector(private val assets: AssetManager) {
    /** Letterboxed pass: prototypes plus the geometry needed to map masks back. */
    private class Pass(val proto: FloatArray, val protoWidth: Int, val protoHeight: Int,
                       val scale: Double, val leftPad: Int, val topPad: Int)

    private class Box(val classId: Int, val score: Float,
                      val left: Double, val top: Double,
                      val right: Double, val bottom: Double,
                      val coefficients: FloatArray, val pass: Pass) {
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
                        "box" to listOf(box.left, box.top, box.right, box.bottom),
                        "mask" to mask(box, bitmap.width, bitmap.height))
                }, "truncated" to (ordered.size > 200),
                "elapsedMs" to (System.nanoTime() - start) / 1_000_000.0)
        } finally { bitmap.recycle() }
    }

    /** Silhouette over the box, as an 8-bit crop of the prototype grid (stride 4
     * of the letterboxed input), with the crop's rectangle in bitmap coordinates. */
    private fun mask(box: Box, width: Int, height: Int): Map<String, Any> {
        val pass = box.pass
        // Box in letterboxed input pixels, then prototype cells (floor/ceil outward).
        val x1 = floor((box.left * pass.scale + pass.leftPad) / 4).toInt().coerceIn(0, pass.protoWidth - 1)
        val y1 = floor((box.top * pass.scale + pass.topPad) / 4).toInt().coerceIn(0, pass.protoHeight - 1)
        val x2 = ceil((box.right * pass.scale + pass.leftPad) / 4).toInt().coerceIn(x1 + 1, pass.protoWidth)
        val y2 = ceil((box.bottom * pass.scale + pass.topPad) / 4).toInt().coerceIn(y1 + 1, pass.protoHeight)
        val w = x2 - x1; val h = y2 - y1
        val bytes = ByteArray(w * h)
        val plane = pass.protoWidth * pass.protoHeight
        for (y in 0 until h) for (x in 0 until w) {
            var sum = 0f
            val cell = (y1 + y) * pass.protoWidth + x1 + x
            for (k in box.coefficients.indices) sum += box.coefficients[k] * pass.proto[k * plane + cell]
            bytes[y * w + x] = (255.0 / (1.0 + exp(-sum.toDouble()))).roundToInt().toByte()
        }
        return mapOf("width" to w, "height" to h, "bytes" to bytes,
            "left" to ((x1 * 4 - pass.leftPad) / pass.scale).coerceIn(0.0, width.toDouble()),
            "top" to ((y1 * 4 - pass.topPad) / pass.scale).coerceIn(0.0, height.toDouble()),
            "right" to ((x2 * 4 - pass.leftPad) / pass.scale).coerceIn(0.0, width.toDouble()),
            "bottom" to ((y2 * 4 - pass.topPad) / pass.scale).coerceIn(0.0, height.toDouble()))
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
                check(shape.size == 3 && shape[0] == 1L && shape[2] == 38L && shape[1] <= 300)
                val protoTensor = output[1] as OnnxTensor
                val protoShape = protoTensor.info.shape
                check(protoShape.size == 4 && protoShape[0] == 1L && protoShape[1] == 32L)
                val proto = FloatArray((protoShape[1] * protoShape[2] * protoShape[3]).toInt())
                protoTensor.floatBuffer.get(proto)
                val pass = Pass(proto, protoShape[3].toInt(), protoShape[2].toInt(), scale, leftPad, topPad)
                val buffer = result.floatBuffer
                val found = mutableListOf<Box>()
                repeat(shape[1].toInt()) {
                    val x1 = buffer.get(); val y1 = buffer.get()
                    val x2 = buffer.get(); val y2 = buffer.get()
                    val score = buffer.get(); val label = buffer.get()
                    val coefficients = FloatArray(32) { buffer.get() }
                    if (listOf(x1, y1, x2, y2, score, label).all { it.isFinite() } &&
                        score >= .25f && label in CLASSES) {
                        val l = ((x1 - leftPad) / scale).coerceIn(0.0, bitmap.width.toDouble())
                        val t = ((y1 - topPad) / scale).coerceIn(0.0, bitmap.height.toDouble())
                        val r = ((x2 - leftPad) / scale).coerceIn(0.0, bitmap.width.toDouble())
                        val b = ((y2 - topPad) / scale).coerceIn(0.0, bitmap.height.toDouble())
                        if (l < r && t < b) found.add(Box(label.toInt(), score, l, t, r, b, coefficients, pass))
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
