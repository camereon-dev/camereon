package dev.camereon.camereon.demo

import android.graphics.Bitmap
import android.os.Handler
import android.os.Looper
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.nio.ByteBuffer
import java.util.concurrent.Executors

/** Bundled, offline OCR; recognized text is never logged or written to disk. */
internal class JapaneseOcrChannel(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.camereon/japanese_ocr")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    private var busy = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "detect") {
                result.notImplemented()
            } else if (closed || busy) {
                result.error("busy", "住所を読み取れませんでした", null)
            } else {
                val bytes = call.argument<ByteArray>("bytes")
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                if (bytes == null || width !in 1..2560 || height !in 1..2560 ||
                    bytes.size != width * height * 4) {
                    result.error("invalidImage", "画像を読み取れませんでした", null)
                } else {
                    busy = true
                    worker.execute {
                        var bitmap: Bitmap? = null
                        var recognizer: com.google.mlkit.vision.text.TextRecognizer? = null
                        try {
                            recognizer = TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
                            val image = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            bitmap = image
                            image.copyPixelsFromBuffer(ByteBuffer.wrap(bytes))
                            val recognized = Tasks.await(recognizer.process(InputImage.fromBitmap(image, 0)))
                            val allLines = recognized.textBlocks.flatMap { it.lines }
                            val lines = allLines.take(1000).map { line ->
                                line.elements.flatMap { element ->
                                    element.symbols.mapNotNull { symbol ->
                                        symbol.boundingBox?.let { box ->
                                            val left = box.left.coerceIn(0, width)
                                            val top = box.top.coerceIn(0, height)
                                            val right = box.right.coerceIn(0, width)
                                            val bottom = box.bottom.coerceIn(0, height)
                                            if (left >= right || top >= bottom) null else mapOf(
                                                "text" to symbol.text,
                                                "box" to listOf(left, top, right, bottom))
                                        }
                                    }
                                }
                            }
                            main.post {
                                busy = false
                                if (!closed) result.success(mapOf("lines" to lines,
                                    "truncated" to (allLines.size > 1000)))
                            }
                        } catch (_: Exception) {
                            main.post {
                                busy = false
                                if (!closed) result.error("failed", "住所を読み取れませんでした", null)
                            }
                        } finally {
                            recognizer?.close()
                            bitmap?.recycle()
                        }
                    }
                }
            }
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
