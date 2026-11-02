package dev.camereon.camereon.demo

import android.content.res.AssetManager
import android.graphics.Bitmap
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.nio.ByteBuffer
import java.nio.FloatBuffer
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Only regions leave native code. One shared, verified session serves every pass.
 * Input is the editor's oriented RGBA pixels: no PNG encode/decode on either side.
 */
internal class TextRegionDetector(private val assets: AssetManager) {
    fun detect(pixels: ByteArray, width: Int, height: Int, detailed: Boolean = true,
               tuning: OnnxSessions.Tuning = OnnxSessions.Tuning()): Map<String, Any> {
        val limit = if (detailed) 2560 else 960
        val cap = if (detailed) 500 else 200
        require(width in 1..limit && height in 1..limit && pixels.size == width * height * 4)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))
        val watch = System.nanoTime()
        try {
            val environment = OnnxSessions.environment
            val merged = mutableListOf<List<Double>>()
            var truncated = false
            var passes = 0
            fun include(box: List<Double>) {
                // A speck of a few pixels is never text the editor could show or tap.
                if (box[2] - box[0] < 8 && box[3] - box[1] < 8) return
                var combined = box
                var index = 0
                while (index < merged.size) {
                    val old = merged[index]
                    if (duplicate(combined, old)) {
                        combined = listOf(min(combined[0], old[0]), min(combined[1], old[1]),
                            max(combined[2], old[2]), max(combined[3], old[3]))
                        merged.removeAt(index)
                        index = 0
                    } else index++
                }
                if (merged.size < cap) merged.add(combined) else truncated = true
            }
            OnnxSessions.use(assets, MODEL, MODEL_SHA256, tuning) { session ->
                // Keep whole-line context at a higher resolution. Tiny
                // detail crops alone can split dates and curved words.
                val overview = infer(bitmap, if (detailed) 1536 else 960, false,
                    session, environment, oriented = detailed)
                passes++
                // The controlled legacy comparison retains its old scoring.
                if (!detailed || max(bitmap.width, bitmap.height) <= 960) {
                    truncated = overview.size > cap
                    merged.addAll(overview.take(cap))
                } else {
                    // Tiles overlap by 64px, enough for the small text they exist
                    // for; longer lines come from the overview. Each tile is
                    // enlarged about 1.5x to 1024px instead of shrinking the
                    // photo until its small characters disappear. At most 4x4.
                    val (tileWidth, xs) = plan(bitmap.width)
                    val (tileHeight, ys) = plan(bitmap.height)
                    check(xs.size <= 4 && ys.size <= 4)
                    for (y in ys) for (x in xs) {
                        val crop = Bitmap.createBitmap(bitmap, x, y,
                            min(tileWidth, bitmap.width - x), min(tileHeight, bitmap.height - y))
                        try {
                            for (box in infer(crop, 1024, true, session, environment)) {
                                val mapped = listOf(box[0] + x, box[1] + y, box[2] + x, box[3] + y)
                                // Enlarged strokes within an already detected
                                // large text line must not become extra words.
                                if (overview.none { isLargeLineFragment(mapped, it) }) include(mapped)
                            }
                            passes++
                        } finally { if (crop !== bitmap) crop.recycle() }
                    }
                    // Prefer a complete finer text line over a blurry,
                    // over-expanded overview box. Partial cropped words do
                    // not replace the complete line from the overview.
                    for (box in overview) {
                        val fineLine = merged.any { fine ->
                            duplicate(fine, box) &&
                                min(fine[2] - fine[0], box[2] - box[0]) /
                                max(fine[2] - fine[0], box[2] - box[0]) >= .8
                        }
                        if (!fineLine) include(box)
                    }
                }
            }
            val rectangles = merged.sortedWith(compareBy({ it[1] }, { it[0] }))
            return mapOf("width" to bitmap.width, "height" to bitmap.height,
                "boxes" to rectangles, "truncated" to truncated, "passes" to passes,
                "elapsedMs" to ((System.nanoTime() - watch) / 1_000_000.0))
        } finally { bitmap.recycle() }
    }

    private fun isLargeLineFragment(a: List<Double>, b: List<Double>): Boolean {
        val bw = b[2] - b[0]; val bh = b[3] - b[1]
        if (min(bw, bh) < 48 || max(bw, bh) / min(bw, bh) < 2) return false
        val aw = a[2] - a[0]; val ah = a[3] - a[1]
        val intersection = max(0.0, min(a[2], b[2]) - max(a[0], b[0])) *
            max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
        val shorter = if (bw >= bh) aw < bw * .9 || ah < bh * .6 else ah < bh * .9 || aw < bw * .6
        return shorter && intersection / (aw * ah) >= .9
    }

    private fun duplicate(a: List<Double>, b: List<Double>): Boolean {
        val aw = a[2] - a[0]; val ah = a[3] - a[1]
        val bw = b[2] - b[0]; val bh = b[3] - b[1]
        val intersection = max(0.0, min(a[2], b[2]) - max(a[0], b[0])) *
            max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
        return intersection / (aw * ah + bw * bh - intersection) >= .45 ||
            (intersection / min(aw * ah, bw * bh) >= .8 && min(ah, bh) / max(ah, bh) >= .35 &&
                abs((a[1] + a[3] - b[1] - b[3]) / 2) <= min(ah, bh) * .5)
    }

    private fun infer(bitmap: Bitmap, side: Int, upscale: Boolean, session: OrtSession,
                      environment: OrtEnvironment, oriented: Boolean = true): List<List<Double>> {
        val scale = if (upscale) side.toDouble() / max(bitmap.width, bitmap.height)
            else min(1.0, side.toDouble() / max(bitmap.width, bitmap.height))
        val firstWidth = max(1, (bitmap.width * scale).roundToInt())
        val firstHeight = max(1, (bitmap.height * scale).roundToInt())
        val first = Bitmap.createScaledBitmap(bitmap, firstWidth, firstHeight, true)
        val width = max(32, (firstWidth / 32.0).roundToInt() * 32)
        val height = max(32, (firstHeight / 32.0).roundToInt() * 32)
        val pixels = IntArray(width * height)
        try {
            val resized = Bitmap.createScaledBitmap(first, width, height, true)
            try { resized.getPixels(pixels, 0, width, 0, 0, width, height) }
            finally { if (resized !== first) resized.recycle() }
        } finally { if (first !== bitmap) first.recycle() }
        val plane = width * height
        val input = FloatArray(plane * 3)
        // Official inference.yml: DecodeImage BGR, then ImageNet mean/std.
        val means = floatArrayOf(.485f, .456f, .406f)
        val stds = floatArrayOf(.229f, .224f, .225f)
        for (i in pixels.indices) for (channel in 0..2) {
            val value = (pixels[i] ushr (8 * channel)) and 255
            input[channel * plane + i] = (value / 255f - means[channel]) / stds[channel]
        }
        return OnnxTensor.createTensor(environment, FloatBuffer.wrap(input),
            longArrayOf(1, 3, height.toLong(), width.toLong())).use { tensor ->
            OnnxSessions.run(session, mapOf(session.inputNames.first() to tensor)) { output ->
                val result = output[0] as OnnxTensor
                val shape = result.info.shape
                require(shape.size == 4 && shape[0] == 1L && shape[1] == 1L)
                val mapHeight = shape[2].toInt(); val mapWidth = shape[3].toInt()
                val p = FloatArray(mapWidth * mapHeight)
                result.floatBuffer.get(p)
                boxes(p, mapWidth, mapHeight, bitmap.width, bitmap.height, upscale, pixels, width, height, oriented)
            }
        }
    }

    // Reject flat-color border hallucinations on a grid of at most 32x32
    // samples; variation along the line rejects solid straight borders.
    private fun hasContrast(p: IntArray, width: Int, height: Int,
                            l: Int, t: Int, r: Int, b: Int): Boolean {
        val left = l.coerceIn(0, width - 1); val top = t.coerceIn(0, height - 1)
        val right = r.coerceIn(left + 1, width); val bottom = b.coerceIn(top + 1, height)
        val sx = max(1, (right - left) / 32); val sy = max(1, (bottom - top) / 32)
        val low = IntArray(3) { 255 }; val high = IntArray(3)
        val projectedLow = IntArray(3) { 255 }; val projectedHigh = IntArray(3)
        val vertical = bottom - top > right - left
        val from = if (vertical) top else left
        val outerEnd = if (vertical) bottom else right
        val outerStep = if (vertical) sy else sx
        for (outer in from until outerEnd step outerStep) {
            val sums = IntArray(3)
            var count = 0
            val innerFrom = if (vertical) left else top
            val innerEnd = if (vertical) right else bottom
            val innerStep = if (vertical) sx else sy
            for (inner in innerFrom until innerEnd step innerStep) {
                val x = if (vertical) inner else outer
                val y = if (vertical) outer else inner
                val pixel = p[y * width + x]
                for (channel in 0..2) {
                    val value = (pixel ushr (8 * channel)) and 255
                    low[channel] = min(low[channel], value); high[channel] = max(high[channel], value)
                    sums[channel] += value
                }
                count++
            }
            for (channel in 0..2) {
                val mean = sums[channel] / count
                projectedLow[channel] = min(projectedLow[channel], mean)
                projectedHigh[channel] = max(projectedHigh[channel], mean)
                if (high[channel] - low[channel] >= 12 &&
                    projectedHigh[channel] - projectedLow[channel] >= 4) return true
            }
        }
        return false
    }

    // DB probability-map components. Score along the text's own orientation;
    // the editor still receives conservative axis-aligned redaction bounds.
    private fun boxes(p: FloatArray, width: Int, height: Int, imageWidth: Int,
                      imageHeight: Int, lineFilter: Boolean = false, pixels: IntArray, pixelWidth: Int, pixelHeight: Int,
                      oriented: Boolean = true): List<List<Double>> {
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
            val geometry = if (oriented) TextBoxGeometry.component(queue, tail, width, top, bottom) else null
            val textWidth = geometry?.width ?: w.toDouble()
            val textHeight = geometry?.height ?: h.toDouble()
            if (min(textWidth, textHeight) < 3) continue
            val score = if (geometry != null) geometry.score(p, width, left, top, right, bottom) else {
                var sum = 0.0
                for (y in top..bottom) for (x in left..right) sum += p[y * width + x]
                sum / (w * h)
            }
            if (score < .6) continue
            // Retain confident single characters/digits instead of rejecting
            // every near-square shape. Require stronger evidence for these
            // crop-only additions to limit repeated fabric-pattern candidates.
            if (lineFilter && max(textWidth, textHeight) / min(textWidth, textHeight) < 1.5 && score < .75) continue
            val margin = textWidth * textHeight * 1.5 / (2 * (textWidth + textHeight))
            if (lineFilter && !hasContrast(pixels, pixelWidth, pixelHeight,
                ((left - margin) * pixelWidth / width).toInt(),
                ((top - margin) * pixelHeight / height).toInt(),
                ceil((right + 1 + margin) * pixelWidth / width).toInt(),
                ceil((bottom + 1 + margin) * pixelHeight / height).toInt())) continue
            found.add(listOf(
                max(0.0, left - margin) * imageWidth / width,
                max(0.0, top - margin) * imageHeight / height,
                min(width.toDouble(), right + 1 + margin) * imageWidth / width,
                min(height.toDouble(), bottom + 1 + margin) * imageHeight / height,
            ))
        }
        return found.sortedWith(compareBy({ it[1] }, { it[0] }))
    }

    companion object {
        const val MODEL = "text_detection/inference.onnx"
        const val MODEL_SHA256 = "a431985659dc921974177a95adcfbb90fd9e51989a5e04d70d0b75f597b6e61d"

        /** Tile edge and offsets along one axis: the fewest tiles of at most
         * 704px (about 1.5x enlargement to 1024px) that overlap by 64px or more. */
        fun plan(length: Int): Pair<Int, List<Int>> {
            val overlap = 64
            val count = max(1, ceil((length - overlap) / 640.0).toInt())
            if (count == 1) return length to listOf(0)
            val edge = ceil((length - overlap).toDouble() / count).toInt() + overlap
            return edge to (0 until count).map { (it * (length - edge).toDouble() / (count - 1)).roundToInt() }
        }
    }
}
