package dev.camereon.camereon.demo

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Handler
import android.os.Looper
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.face.FaceDetection
import com.google.mlkit.vision.face.FaceDetectorOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import kotlin.math.max
import kotlin.math.roundToInt

/** One in-flight request. Images never touch disk; no Gemma dependencies. */
class MlKitFaceDetectionHandler(messenger: BinaryMessenger) {
    private val channel = MethodChannel(messenger, "dev.camereon/face_detection")
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var closed = false
    private var busy = false

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method != "detect") {
                result.notImplemented()
            } else if (closed || busy) {
                result.error("busy", "Face detector unavailable", null)
            } else {
                val bytes = call.argument<ByteArray>("bytes")
                val width = call.argument<Int>("width") ?: 0
                val height = call.argument<Int>("height") ?: 0
                if (bytes == null || bytes.size > 128 * 1024 * 1024 ||
                    width <= 0 || height <= 0 || width.toLong() * height > 24000000) {
                    result.error("invalidImage", "Invalid source image", null)
                } else {
                    busy = true
                    worker.execute { detect(bytes, width, height, result) }
                }
            }
        }
    }

    private fun detect(bytes: ByteArray, width: Int, height: Int, result: MethodChannel.Result) {
        var bitmap: Bitmap? = null
        var detector: com.google.mlkit.vision.face.FaceDetector? = null
        try {
            detector = FaceDetection.getClient(FaceDetectorOptions.Builder()
            .setPerformanceMode(FaceDetectorOptions.PERFORMANCE_MODE_ACCURATE)
            .setMinFaceSize(0.05f)
            .build())
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            require(bounds.outWidth == width && bounds.outHeight == height)
            val options = BitmapFactory.Options().apply { inSampleSize = 1 }
            while (max(width, height) / options.inSampleSize > 3200) options.inSampleSize *= 2
            val decoded = requireNotNull(BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options))
            bitmap = decoded
            val scale = minOf(1.0, 1600.0 / max(decoded.width, decoded.height))
            if (scale < 1.0) {
                bitmap = Bitmap.createScaledBitmap(decoded,
                    max(1, (decoded.width * scale).roundToInt()),
                    max(1, (decoded.height * scale).roundToInt()), true)
                if (bitmap !== decoded) decoded.recycle()
            }
            val input = requireNotNull(bitmap)
            if (closed) throw IllegalStateException("Closed")
            val faces = com.google.android.gms.tasks.Tasks.await(
                detector.process(InputImage.fromBitmap(input, 0)))
            val response = mapOf(
                "width" to input.width, "height" to input.height,
                "faces" to faces.map { face ->
                    val r = face.boundingBox
                    listOf(r.left, r.top, r.right, r.bottom)
                })
            main.post { busy = false; result.success(response) }
        } catch (_: Exception) {
            main.post { busy = false; result.error("detectionFailed", "Face detection failed", null) }
        } finally {
            bitmap?.recycle()
            detector?.close()
        }
    }

    fun close() {
        closed = true
        channel.setMethodCallHandler(null)
        // Let in-flight inference finish before releasing its image and detector.
        worker.shutdown()
    }
}
