package dev.camereon.camereon.demo

import android.content.res.AssetManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.FloatBuffer
import java.security.MessageDigest
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Detection only: no recognition model, vocabulary, text output or network IO. */
internal class TextRegionDetector(private val assets: AssetManager) {
    fun detect(bytes: ByteArray): Map<String, Any> {
        require(bytes.isNotEmpty() && bytes.size <= 8 * 1024 * 1024)
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        require(bounds.outWidth in 1..960 && bounds.outHeight in 1..960)
        val bitmap = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size))
        val watch = System.nanoTime()
        try {
            val width = max(32, (bitmap.width / 32.0).roundToInt() * 32)
            val height = max(32, (bitmap.height / 32.0).roundToInt() * 32)
            val resized = Bitmap.createScaledBitmap(bitmap, width, height, true)
            val pixels = IntArray(width * height)
            try { resized.getPixels(pixels, 0, width, 0, 0, width, height) }
            finally { if (resized !== bitmap) resized.recycle() }
            val plane = width * height
            val input = FloatArray(plane * 3)
            // Official inference.yml: DecodeImage BGR, then ImageNet mean/std.
            val means = floatArrayOf(.485f, .456f, .406f)
            val stds = floatArrayOf(.229f, .224f, .225f)
            for (i in pixels.indices) {
                for (channel in 0..2) {
                    val value = (pixels[i] ushr (8 * channel)) and 255
                    input[channel * plane + i] = (value / 255f - means[channel]) / stds[channel]
                }
            }
            val model = assets.open("text_detection/inference.onnx").use { it.readBytes() }
            val hash = MessageDigest.getInstance("SHA-256").digest(model)
                .joinToString("") { "%02x".format(it.toInt() and 255) }
            check(hash == "a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d")
            val environment = OrtEnvironment.getEnvironment()
            val rectangles = OrtSession.SessionOptions().use { options ->
                options.setIntraOpNumThreads(2)
                options.setInterOpNumThreads(1)
                environment.createSession(model, options).use { session ->
                    OnnxTensor.createTensor(environment, FloatBuffer.wrap(input),
                        longArrayOf(1, 3, height.toLong(), width.toLong())).use { tensor ->
                        session.run(mapOf(session.inputNames.first() to tensor)).use { output ->
                            val tensorOutput = output[0] as OnnxTensor
                            val shape = tensorOutput.info.shape
                            require(shape.size == 4 && shape[0] == 1L && shape[1] == 1L)
                            val mapHeight = shape[2].toInt()
                            val mapWidth = shape[3].toInt()
                            val probabilities = FloatArray(mapWidth * mapHeight)
                            tensorOutput.floatBuffer.get(probabilities)
                            boxes(probabilities, mapWidth, mapHeight, bitmap.width, bitmap.height)
                        }
                    }
                }
            }
            return mapOf("width" to bitmap.width, "height" to bitmap.height,
                "boxes" to rectangles.take(200), "truncated" to (rectangles.size > 200),
                "elapsedMs" to ((System.nanoTime() - watch) / 1_000_000.0))
        } finally { bitmap.recycle() }
    }

    // DB probability-map components. Axis-aligned bounds deliberately cover rotated
    // text too; rectangular expansion approximates DB unclip without OpenCV.
    private fun boxes(p: FloatArray, width: Int, height: Int, imageWidth: Int,
                      imageHeight: Int): List<List<Double>> {
        val visited = BooleanArray(p.size)
        val queue = IntArray(p.size)
        val found = mutableListOf<List<Double>>()
        for (seed in p.indices) {
            if (visited[seed] || p[seed] < .3f) continue
            var head = 0
            var tail = 1
            queue[0] = seed
            visited[seed] = true
            var left = width; var right = 0; var top = height; var bottom = 0
            while (head < tail) {
                val index = queue[head++]
                val x = index % width; val y = index / width
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
                // Four-connected traversal, without wrapping across row boundaries.
                for (direction in 0..3) {
                    val next = when (direction) {
                        0 -> if (x > 0) index - 1 else -1
                        1 -> if (x + 1 < width) index + 1 else -1
                        2 -> if (y > 0) index - width else -1
                        else -> if (y + 1 < height) index + width else -1
                    }
                    if (next >= 0 && !visited[next] && p[next] >= .3f) {
                        visited[next] = true; queue[tail++] = next
                    }
                }
            }
            val w = right - left + 1; val h = bottom - top + 1
            if (min(w, h) < 3) continue
            var score = 0.0
            for (y in top..bottom) for (x in left..right) score += p[y * width + x]
            if (score / (w * h) < .6) continue
            val margin = w.toDouble() * h * 1.5 / (2 * (w + h))
            found.add(listOf(
                max(0.0, left - margin) * imageWidth / width,
                max(0.0, top - margin) * imageHeight / height,
                min(width.toDouble(), right + 1 + margin) * imageWidth / width,
                min(height.toDouble(), bottom + 1 + margin) * imageHeight / height,
            ))
        }
        return found.sortedWith(compareBy({ it[1] }, { it[0] }))
    }
}
