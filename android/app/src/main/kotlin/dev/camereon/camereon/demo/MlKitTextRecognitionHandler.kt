import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt
import com.google.android.gms.tasks.Tasks

/** One in-flight request. Images never touch disk; no Gemma dependencies. */
class MlKitTextRecognitionHandler(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.camereon/text_recognition")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    private var busy = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "recognize") {
                result.notImplemented()
            } else if (closed || busy) {
                result.error("busy", "Text recognizer unavailable", null)
            } else {
                val bytes = call.argument<ByteArray>("bytes")
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                if (bytes == null || width <= 0 || height <= 0) {
                    result.error("invalidImage", "Invalid source image", null)
                } else {
                    busy = true
                    worker.execute { recognize(bytes, width, height, result) }
                }
            }
        }
    }

    private fun recognize(bytes: ByteArray, width: Int, height: Int, result: MethodChannel.Result) {
        var bitmap: Bitmap? = null
        try {
            val recognizer = TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
            val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
            bitmap = decoded
            
            val input = InputImage.fromBitmap(bitmap, 0)
            val text = Tasks.await(recognizer.process(input))
            
            val response = text.textBlocks.map { block ->
                mapOf(
                    "text" to block.text,
                    "box" to listOf(block.boundingBox?.left, block.boundingBox?.top, block.boundingBox?.right, block.boundingBox?.bottom)
                )
            }
            
            main.post { busy = false; if (!closed) result.success(response) }
        } catch (_: Throwable) {
            main.post { busy = false; if (!closed) result.error("recognitionFailed", "Text recognition failed", null) }
        } finally {
            bitmap?.recycle()
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        worker.shutdown()
    }
}
