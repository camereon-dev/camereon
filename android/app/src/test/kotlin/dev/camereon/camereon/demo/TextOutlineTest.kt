package dev.camereon.camereon.demo

import dev.camereon.camereon.demo.TextBoxGeometry.Point
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class TextOutlineTest {
    @Test fun hullDropsInteriorAndCollinearPoints() {
        val hull = TextBoxGeometry.hull(listOf(
            Point(0.0, 0.0), Point(4.0, 0.0), Point(4.0, 4.0), Point(0.0, 4.0),
            Point(2.0, 2.0), Point(2.0, 0.0), Point(1.0, 3.0)))
        assertEquals(4, hull.size)
        assertEquals(setOf(Point(0.0, 0.0), Point(4.0, 0.0), Point(4.0, 4.0), Point(0.0, 4.0)), hull.toSet())
    }

    @Test fun grownOutlineEnclosesTheOriginalByTheMargin() {
        val square = TextBoxGeometry.hull(listOf(Point(10.0, 10.0), Point(20.0, 10.0), Point(20.0, 14.0), Point(10.0, 14.0)))
        val grown = TextBoxGeometry.grown(square, 3.0)
        assertTrue(grown.size >= 4)
        assertEquals(7.0, grown.minOf { it.x }, 1e-9)
        assertEquals(23.0, grown.maxOf { it.x }, 1e-9)
        assertEquals(7.0, grown.minOf { it.y }, 1e-9)
        assertEquals(17.0, grown.maxOf { it.y }, 1e-9)
        // Every original corner lies strictly inside the grown polygon's bounds.
        for (p in square) assertTrue(p.x > 7.0 && p.x < 23.0 && p.y > 7.0 && p.y < 17.0)
    }

    @Test fun componentOutlineFollowsASlantedStroke() {
        // A diagonal run of pixels, one per row, shifting right by one each row.
        val width = 32
        val indices = IntArray(8) { row -> (5 + row) * width + (3 + row) }
        val outline = TextBoxGeometry.outline(indices, indices.size, width, 5, 12)
        assertTrue(outline.size in 4..8)
        assertEquals(3.0, outline.minOf { it.x }, 1e-9)
        assertEquals(11.0, outline.maxOf { it.x }, 1e-9)
        assertEquals(5.0, outline.minOf { it.y }, 1e-9)
        assertEquals(13.0, outline.maxOf { it.y }, 1e-9)
        // The slanted hull leaves the off-diagonal corners of the bounding box outside.
        fun inside(x: Double, y: Double): Boolean {
            var sign = 0
            for (i in outline.indices) {
                val a = outline[i]; val b = outline[(i + 1) % outline.size]
                val cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
                val s = if (cross > 1e-9) 1 else if (cross < -1e-9) -1 else 0
                if (s != 0) { if (sign == 0) sign = s else if (sign != s) return false }
            }
            return true
        }
        assertTrue(inside(7.5, 9.5))
        assertTrue(!inside(10.5, 5.5))
        assertTrue(!inside(3.5, 12.5))
    }
}
