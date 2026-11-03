package dev.camereon.camereon.demo

import android.app.Activity
import android.view.OrientationEventListener
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** How the phone is physically held, from the accelerometer.
 *
 * The activity is portrait-locked, so the display rotation (which the camera
 * plugin reports as "device orientation" and uses for capture) never changes.
 * Dart receives "changed" (and can ask for "current") with two clockwise angles
 * in 0/90/180/270: `capture`, relative to the device's natural orientation, as
 * CameraX target rotation expects; and `ui`, relative to the screen as drawn,
 * for keeping icons upright. They differ only on landscape-natural tablets.
 */
internal class DeviceRotationChannel(private val activity: Activity, engine: FlutterEngine) {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, "dev.camereon/device_rotation")
    private var rotation: Int? = null
    private val listener = object : OrientationEventListener(activity) {
        override fun onOrientationChanged(orientation: Int) {
            if (orientation == ORIENTATION_UNKNOWN) return // lying flat: keep the last value
            val next = DeviceRotation.of(orientation, rotation)
            if (next != rotation) {
                rotation = next
                channel.invokeMethod("changed", message(next))
            }
        }
    }

    init {
        channel.setMethodCallHandler { call, result ->
            if (call.method == "current") result.success(rotation?.let(::message)) else result.notImplemented()
        }
    }

    private fun message(capture: Int): Map<String, Int> {
        // Surface.ROTATION_0..3 of the drawn screen, in clockwise degrees.
        val display = (activity.display?.rotation ?: 0) * 90
        return mapOf("capture" to capture, "ui" to (capture - display + 360) % 360)
    }

    fun resume() {
        if (listener.canDetectOrientation()) listener.enable()
    }

    fun pause() = listener.disable()

    fun close() {
        listener.disable()
        channel.setMethodCallHandler(null)
    }
}

internal object DeviceRotation {
    /** CameraX's documented mapping from [OrientationEventListener] degrees to a
     * target rotation, as clockwise degrees. Near a boundary the previous value
     * is kept until the phone is clearly past it (10° hysteresis). */
    fun of(orientation: Int, previous: Int?): Int {
        val degrees = ((orientation % 360) + 360) % 360
        if (previous != null) {
            val held = (360 - previous) % 360 // sensor angle where `previous` is centred
            val distance = minOf((degrees - held + 360) % 360, (held - degrees + 360) % 360)
            if (distance <= 55) return previous
        }
        val centre = ((degrees + 45) / 90 % 4) * 90
        return (360 - centre) % 360
    }
}
