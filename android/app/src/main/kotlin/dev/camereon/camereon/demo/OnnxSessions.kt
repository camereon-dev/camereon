package dev.camereon.camereon.demo

import android.content.res.AssetManager
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import ai.onnxruntime.OrtSession
import java.security.MessageDigest

/** Verified sessions are built once per process and shared by later photos.
 * Every model is hashed before its first session; a mismatch never runs.
 * Release under memory pressure; the next photo rebuilds what it needs.
 * A release requested during inference waits for the last user to finish.
 */
internal object OnnxSessions {
    /** Leave one core to the UI: 2 to 4 inference threads depending on the device.
     * On a 4-core emulator, 4 threads were 1.2-2.3x faster than 2; XNNPACK was slower. */
    val defaultThreads: Int = (Runtime.getRuntime().availableProcessors() - 1).coerceIn(2, 4)

    data class Tuning(val threads: Int = defaultThreads)

    val environment: OrtEnvironment get() = OrtEnvironment.getEnvironment()
    private val sessions = HashMap<String, OrtSession>()
    private var active = 0
    private var releaseRequested = false

    fun <T> use(assets: AssetManager, asset: String, sha256: String, tuning: Tuning,
                block: (OrtSession) -> T): T {
        val session = acquire(assets, asset, sha256, tuning)
        try { return block(session) } finally { done() }
    }

    @Synchronized
    private fun acquire(assets: AssetManager, asset: String, sha256: String, tuning: Tuning): OrtSession {
        val key = "$asset|$tuning"
        val session = sessions[key] ?: create(assets, asset, sha256, tuning).also { sessions[key] = it }
        active++
        return session
    }

    @Synchronized
    private fun done() {
        active--
        if (active == 0 && releaseRequested) closeAll()
    }

    /** Return the arena chunks a run no longer needs. A cached session then
     * keeps its weights, not the peak working memory of its largest input. */
    fun <T> run(session: OrtSession, inputs: Map<String, OnnxTensor>, block: (OrtSession.Result) -> T): T =
        OrtSession.RunOptions().use { options ->
            options.addRunConfigEntry("memory.enable_memory_arena_shrinkage", "cpu:0")
            session.run(inputs, options).use(block)
        }

    @Synchronized
    fun release() {
        if (active == 0) closeAll() else releaseRequested = true
    }

    private fun closeAll() {
        releaseRequested = false
        for (session in sessions.values) runCatching { session.close() }
        sessions.clear()
    }

    private fun create(assets: AssetManager, asset: String, sha256: String, tuning: Tuning): OrtSession {
        val model = assets.open(asset).use { it.readBytes() }
        val hash = MessageDigest.getInstance("SHA-256").digest(model)
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        check(hash == sha256)
        OrtSession.SessionOptions().use { options ->
            options.setInterOpNumThreads(1)
            options.setIntraOpNumThreads(tuning.threads)
            return environment.createSession(model, options)
        }
    }
}
