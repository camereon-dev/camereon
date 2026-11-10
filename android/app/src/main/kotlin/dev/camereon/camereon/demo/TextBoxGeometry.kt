package dev.camereon.camereon.demo

import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt

/** Minimum-area rectangle of a connected component, in probability-map pixels.
 * Score all pixels inside the rectangle, including holes/background between
 * strokes. Scoring only the thresholded component would accept sparse noise.
 * This geometry needs no Android/OpenCV objects and adds no inference pass.
 */
internal data class TextBoxGeometry(
    val cosine: Double, val sine: Double,
    val minU: Double, val maxU: Double, val minV: Double, val maxV: Double,
) {
    val width get() = maxU - minU + 1
    val height get() = maxV - minV + 1

    fun score(p: FloatArray, mapWidth: Int, left: Int, top: Int, right: Int, bottom: Int): Double {
        var sum = 0.0
        var count = 0
        for (y in top..bottom) for (x in left..right) {
            val u = x * cosine + y * sine
            val v = -x * sine + y * cosine
            if (u >= minU - .500001 && u <= maxU + .500001 &&
                v >= minV - .500001 && v <= maxV + .500001) {
                sum += p[y * mapWidth + x]
                count++
            }
        }
        return if (count == 0) 0.0 else sum / count
    }

    /** A point in probability-map or image pixels. */
    data class Point(val x: Double, val y: Double)

    companion object {
        private fun cross(a: Point, b: Point, c: Point) =
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)

        /** Convex hull (monotone chain), counter-clockwise, without the repeated end. */
        fun hull(input: List<Point>): List<Point> {
            val points = input.sortedWith(compareBy({ it.x }, { it.y })).distinct()
            if (points.size < 3) return points
            fun half(sequence: List<Point>): List<Point> {
                val chain = mutableListOf<Point>()
                for (point in sequence) {
                    while (chain.size >= 2 && cross(chain[chain.size - 2], chain.last(), point) <= 0) {
                        chain.removeAt(chain.lastIndex)
                    }
                    chain.add(point)
                }
                return chain.dropLast(1)
            }
            return half(points) + half(points.asReversed())
        }

        /** Grow a convex polygon outward by [margin]: offset every edge, then
         * hull the offset corners (bevelled corners, never spikes). */
        fun grown(polygon: List<Point>, margin: Double): List<Point> {
            if (polygon.size < 3 || margin <= 0) return polygon
            val extra = mutableListOf<Point>()
            for (i in polygon.indices) {
                val a = polygon[i]; val b = polygon[(i + 1) % polygon.size]
                val dx = b.x - a.x; val dy = b.y - a.y
                val length = sqrt(dx * dx + dy * dy)
                if (length == 0.0) continue
                // Outward normal of a counter-clockwise polygon (y grows downward).
                val nx = dy / length * margin; val ny = -dx / length * margin
                extra.add(Point(a.x + nx, a.y + ny)); extra.add(Point(b.x + nx, b.y + ny))
            }
            return hull(extra.ifEmpty { polygon })
        }

        /** The component's hull in probability-map pixel coordinates. */
        fun outline(indices: IntArray, count: Int, mapWidth: Int, top: Int, bottom: Int): List<Point> {
            val lefts = IntArray(bottom - top + 1) { Int.MAX_VALUE }
            val rights = IntArray(lefts.size) { -1 }
            for (i in 0 until count) {
                val x = indices[i] % mapWidth
                val row = indices[i] / mapWidth - top
                lefts[row] = min(lefts[row], x)
                rights[row] = max(rights[row], x)
            }
            val points = mutableListOf<Point>()
            for (row in lefts.indices) if (rights[row] >= 0) {
                // Pixel corners, so the outline encloses whole pixels.
                val y = (top + row).toDouble()
                points.add(Point(lefts[row].toDouble(), y)); points.add(Point(lefts[row].toDouble(), y + 1))
                points.add(Point(rights[row] + 1.0, y)); points.add(Point(rights[row] + 1.0, y + 1))
            }
            return hull(points)
        }

        fun component(indices: IntArray, count: Int, mapWidth: Int, top: Int, bottom: Int): TextBoxGeometry {
            // Only each row's extreme points can belong to the convex hull.
            // At most 2 * mapHeight points, rather than one object per pixel.
            val lefts = IntArray(bottom - top + 1) { Int.MAX_VALUE }
            val rights = IntArray(lefts.size) { -1 }
            for (i in 0 until count) {
                val x = indices[i] % mapWidth
                val row = indices[i] / mapWidth - top
                lefts[row] = min(lefts[row], x)
                rights[row] = max(rights[row], x)
            }
            val points = mutableListOf<Point>()
            for (row in lefts.indices) if (rights[row] >= 0) {
                points.add(Point(lefts[row].toDouble(), (top + row).toDouble()))
                if (rights[row] != lefts[row]) points.add(Point(rights[row].toDouble(), (top + row).toDouble()))
            }
            points.sortWith(compareBy({ it.x }, { it.y }))
            fun half(input: List<Point>): List<Point> {
                val hull = mutableListOf<Point>()
                for (point in input) {
                    while (hull.size >= 2 && cross(hull[hull.size - 2], hull.last(), point) <= 0) {
                        hull.removeAt(hull.lastIndex)
                    }
                    hull.add(point)
                }
                return hull.dropLast(1)
            }
            val hull = half(points) + half(points.asReversed())
            if (hull.size < 2) {
                val point = points.first()
                return TextBoxGeometry(1.0, 0.0, point.x, point.x, point.y, point.y)
            }
            var best: TextBoxGeometry? = null
            var area = Double.POSITIVE_INFINITY
            for (i in hull.indices) {
                val a = hull[i]; val b = hull[(i + 1) % hull.size]
                val dx = b.x - a.x; val dy = b.y - a.y
                val length = sqrt(dx * dx + dy * dy)
                if (length == 0.0) continue
                val co = dx / length; val si = dy / length
                var minU = Double.POSITIVE_INFINITY; var maxU = Double.NEGATIVE_INFINITY
                var minV = Double.POSITIVE_INFINITY; var maxV = Double.NEGATIVE_INFINITY
                for (point in hull) {
                    val u = point.x * co + point.y * si
                    val v = -point.x * si + point.y * co
                    minU = min(minU, u); maxU = max(maxU, u)
                    minV = min(minV, v); maxV = max(maxV, v)
                }
                val candidateArea = (maxU - minU) * (maxV - minV)
                if (candidateArea < area - 1e-8) {
                    best = TextBoxGeometry(co, si, minU, maxU, minV, maxV)
                    area = candidateArea
                }
            }
            return requireNotNull(best)
        }
    }
}
