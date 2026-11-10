package dev.camereon.camereon.demo

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TextTilePlanTest {
    @Test fun tilesCoverTheAxisWithAtLeastTheMinimumOverlap() {
        for (length in listOf(705, 961, 1024, 1308, 1780, 1920, 2475, 2560)) {
            val (edge, starts) = TextRegionDetector.plan(length)
            assertTrue("$length", edge <= 704)
            assertTrue("$length", starts.size <= 4)
            assertEquals(0, starts.first())
            assertEquals(length, starts.last() + edge)
            for (i in 1 until starts.size) assertTrue("$length", starts[i - 1] + edge - starts[i] >= 64)
        }
    }

    @Test fun shortAxesUseASingleTile() {
        for (length in listOf(300, 640, 704)) assertEquals(length to listOf(0), TextRegionDetector.plan(length))
    }

    @Test fun largestTransferUsesSixteenTiles() {
        val (edge, starts) = TextRegionDetector.plan(2560)
        assertEquals(688, edge)
        assertEquals(listOf(0, 624, 1248, 1872), starts)
        assertEquals(3, TextRegionDetector.plan(1920).second.size)
    }
}
