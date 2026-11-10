package dev.camereon.camereon.demo

import org.junit.Assert.assertEquals
import org.junit.Test

class DeviceRotationTest {
    @Test fun followsCameraXBuckets() {
        // Upright, left side up (turned clockwise), upside down, right side up.
        assertEquals(0, DeviceRotation.of(0, null))
        assertEquals(0, DeviceRotation.of(30, null))
        assertEquals(270, DeviceRotation.of(90, null))
        assertEquals(180, DeviceRotation.of(180, null))
        assertEquals(90, DeviceRotation.of(270, null))
        assertEquals(0, DeviceRotation.of(350, null))
    }

    @Test fun keepsThePreviousValueNearABoundary() {
        assertEquals(0, DeviceRotation.of(50, 0))
        assertEquals(270, DeviceRotation.of(60, 0))
        assertEquals(270, DeviceRotation.of(40, 270))
        assertEquals(0, DeviceRotation.of(30, 270))
        assertEquals(90, DeviceRotation.of(220, 90))
        assertEquals(180, DeviceRotation.of(200, 90))
    }
}
