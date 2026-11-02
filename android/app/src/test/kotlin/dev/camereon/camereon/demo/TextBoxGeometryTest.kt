package dev.camereon.camereon.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

class TextBoxGeometryTest {
    @Test fun tiltedTextIsNotPenalizedByBackgroundOutsideItsOrientation() {
        for (slope in listOf(-.6, .6)) {
            val width = 160
            val p = FloatArray(width * 140)
            val indices = mutableListOf<Int>()
            for (y in 0 until 140) for (x in 10..140) {
                if (abs(y - (70 + slope * (x - 75))) <= 4) {
                    p[y * width + x] = .95f
                    indices.add(y * width + x)
                }
            }
            val top = indices.minOf { it / width }
            val bottom = indices.maxOf { it / width }
            val geometry = TextBoxGeometry.component(indices.toIntArray(), indices.size, width, top, bottom)
            val axisScore = indices.size * .95 / (131 * (bottom - top + 1))
            assertTrue(axisScore < .3)
            assertTrue(geometry.score(p, width, 10, top, 140, bottom) > .85)
        }
    }

    @Test fun backgroundInsideTheRectangleStillLowersConfidence() {
        val width = 40
        val p = FloatArray(width * 40)
        val border = mutableListOf<Int>()
        for (y in 5..34) for (x in 5..34) if (x == 5 || x == 34 || y == 5 || y == 34) {
            border.add(y * width + x)
            p[y * width + x] = .95f
        }
        val geometry = TextBoxGeometry.component(border.toIntArray(), border.size, width, 5, 34)
        assertTrue(geometry.score(p, width, 5, 5, 34, 34) < .2)
    }

    @Test fun horizontalAndSingleCharacterBoundsRemainInMapCoordinates() {
        for ((left, top, right, bottom) in listOf(listOf(12, 7, 80, 15), listOf(30, 40, 39, 49))) {
            val width = 100
            val indices = (top..bottom).flatMap { y -> (left..right).map { x -> y * width + x } }.toIntArray()
            val p = FloatArray(width * 100)
            for (index in indices) p[index] = .9f
            val geometry = TextBoxGeometry.component(indices, indices.size, width, top, bottom)
            assertEquals(.9, geometry.score(p, width, left, top, right, bottom), 1e-6)
            assertEquals(((right - left + 1) * (bottom - top + 1)).toDouble(), geometry.width * geometry.height, 1e-6)
        }
    }
}
