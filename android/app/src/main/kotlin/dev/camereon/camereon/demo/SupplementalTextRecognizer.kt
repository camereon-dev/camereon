package dev.camereon.camereon.demo

import android.graphics.Bitmap
import com.google.android.gms.tasks.Tasks
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions
import kotlin.math.max
import kotlin.math.min

/** A second, bundled OCR pipeline can recover regions missed by the detector.
 * Readable strings are used only in memory to reject empty/non-text results;
 * they are never logged, persisted, or returned over the method channel.
 * Call on the text channel's worker, not Android's main thread.
 */
internal class SupplementalTextRecognizer {
    fun regions(bitmap: Bitmap): List<List<Double>> {
        val recognizer = TextRecognition.getClient(JapaneseTextRecognizerOptions.Builder().build())
        try {
            val result = Tasks.await(recognizer.process(InputImage.fromBitmap(bitmap, 0)))
            // Words/elements avoid a single large rectangle across several
            // curved labels. Only this additive stage uses OCR confidence;
            // low-confidence recognition never removes a detector candidate.
            return result.textBlocks.asSequence().flatMap { it.lines.asSequence() }
                .flatMap { it.elements.asSequence() }.mapNotNull { element ->
                if (element.confidence < .5f || element.text.none { it.isLetterOrDigit() }) return@mapNotNull null
                val bounds = element.boundingBox ?: return@mapNotNull null
                // A small margin covers antialiasing and character-edge errors.
                val margin = max(2.0, min(bounds.width(), bounds.height()) * .08)
                val left = max(0.0, bounds.left - margin)
                val top = max(0.0, bounds.top - margin)
                val right = min(bitmap.width.toDouble(), bounds.right + margin)
                val bottom = min(bitmap.height.toDouble(), bounds.bottom + margin)
                if (right <= left || bottom <= top) null else listOf(left, top, right, bottom)
            }.take(501).toList()
        } finally { recognizer.close() }
    }
}
