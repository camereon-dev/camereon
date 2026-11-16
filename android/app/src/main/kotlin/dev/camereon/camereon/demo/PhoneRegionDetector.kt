package dev.camereon.camereon.demo

import android.graphics.Bitmap
import android.graphics.Rect
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import java.nio.ByteBuffer
import kotlin.math.max

/** Bundled, offline OCR. Only the coordinates of matched phone digits leave native memory. */
internal class PhoneRegionDetector {
    data class Result(val boxes: List<List<Double>>, val truncated: Boolean)
    private data class Glyph(val start: Int, val end: Int, val rect: Rect?)

    fun detect(pixels: ByteArray, width: Int, height: Int): Result {
        require(width in 1..2560 && height in 1..2560 && pixels.size == width * height * 4)
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)
        try {
            bitmap.copyPixelsFromBuffer(ByteBuffer.wrap(pixels))
            val recognized = Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0)))
            val boxes = mutableListOf<List<Double>>()
            for (block in recognized.textBlocks) for (line in block.lines) {
                val text = StringBuilder()
                val glyphs = mutableListOf<Glyph>()
                for (element in line.elements) {
                    if (text.isNotEmpty()) text.append(' ')
                    val symbols = element.symbols
                    if (symbols.isNotEmpty() && symbols.joinToString("") { it.text } == element.text) {
                        for (symbol in symbols) {
                            val start = text.length
                            text.append(symbol.text)
                            glyphs.add(Glyph(start, text.length, symbol.boundingBox))
                        }
                    } else {
                        val start = text.length
                        text.append(element.text)
                        glyphs.add(Glyph(start, text.length, element.boundingBox))
                    }
                }
                for (span in PhoneNumberMatcher.spans(text.toString())) {
                    val included = glyphs.filter { it.start < span.end && it.end > span.start }
                    // Do not hide the rest of an element when symbol-level geometry is missing.
                    if (included.isEmpty() || included.any {
                        it.start < span.start || it.end > span.end || it.rect == null || it.rect.isEmpty
                    }) continue
                    val rect = Rect(included.first().rect!!)
                    included.drop(1).forEach { rect.union(it.rect!!) }
                    val pad = max(1.0, rect.height() * .06).coerceAtMost(3.0)
                    val box = listOf(
                        (rect.left - pad).coerceIn(0.0, width.toDouble()),
                        (rect.top - pad).coerceIn(0.0, height.toDouble()),
                        (rect.right + pad).coerceIn(0.0, width.toDouble()),
                        (rect.bottom + pad).coerceIn(0.0, height.toDouble()),
                    )
                    if (box !in boxes) boxes.add(box)
                    if (boxes.size > 100) return Result(boxes.take(100), true)
                }
            }
            return Result(boxes, false)
        } finally {
            recognizer.close()
            bitmap.recycle()
        }
    }
}
