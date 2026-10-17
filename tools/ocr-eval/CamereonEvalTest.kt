package com.paddle.ocr.eval

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.paddle.ocr.EngineConfig
import com.paddle.ocr.PaddleOCR
import com.paddle.ocr.PaddleOCRConfig
import com.paddle.ocr.util.OpenCVUtils
import kotlinx.coroutines.runBlocking
import org.junit.Test
import org.junit.runner.RunWith

// camereon 向けの評価: モデルごとに日本語画像の認識結果と処理時間をログに出す。
// run.sh が PaddleOCR 公式の Android SDK（deploy/ppocr-android）の androidTest に配置する。
//
// 引数（am instrument -e）:
//   model     … 対象モデルを 1 つに絞る（例: PP-OCRv6_small）
//   limitSide … 検出前に長辺をこの値へ縮小する。未指定なら公式の既定（短辺 64 以上、実質は等倍）
//   threads   … ONNX Runtime のスレッド数（既定 4）
@RunWith(AndroidJUnit4::class)
class CamereonEvalTest {
    @Test
    fun evaluate() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val args = InstrumentationRegistry.getArguments()
        OpenCVUtils.init(context)

        val only = args.getString("model")
        val threads = args.getString("threads")?.toInt() ?: 4
        val limitSide = args.getString("limitSide")?.toInt()
        val config = if (limitSide == null) {
            PaddleOCRConfig()
        } else {
            PaddleOCRConfig(detLimitSideLen = limitSide, detLimitType = "max")
        }
        val images = context.assets.list("eval")!!.filter { it.endsWith(".jpg") }.sorted()
        val models = context.assets.list("models_eval")!!.sorted().filter { only == null || it == only }

        for (model in models) {
            val base = "models_eval/$model"
            val ocr = runBlocking {
                PaddleOCR.create(
                    context, config, EngineConfig(numThreads = threads),
                    detModelAssetPath = "$base/det/inference.onnx",
                    recModelAssetPath = "$base/rec/inference.onnx",
                    recConfigAssetPath = "$base/rec/inference.yml",
                )
            }
            println("[EVAL] model=$model limitSide=$limitSide threads=$threads coldLoadMs=${ocr.coldLoadTimeMs}")
            for (name in images) {
                val bytes = context.assets.open("eval/$name").readBytes()
                runBlocking { repeat(2) { ocr.recognize(bytes) } } // ウォームアップ
                val runs = runBlocking { (1..5).map { ocr.recognize(bytes) } }
                fun median(pick: (com.paddle.ocr.model.OCRRunResult) -> Long) = runs.map(pick).sorted()[2]
                val r = runs.last()
                println(
                    "[EVAL] model=$model image=$name lines=${r.lineCount} medianMs " +
                        "total=${median { it.totalTimeMs }} det=${median { it.detectionTimeMs }} rec=${median { it.recognitionTimeMs }}",
                )
                r.results.forEach {
                    val p = it.box.points
                    println("[EVAL]   ${"%.2f".format(it.confidence)} \"${it.text}\" box=(${p[0].x.toInt()},${p[0].y.toInt()})-(${p[2].x.toInt()},${p[2].y.toInt()})")
                }
            }
            runBlocking { ocr.release() }
        }
    }
}
