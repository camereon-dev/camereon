package dev.camereon.camereon.demo

/** Japanese telephone candidates, not a subscriber/existence check.
 * Offsets are UTF-16 offsets in the original OCR line. Normalization is 1:1.
 * No text is logged, persisted or returned over the platform channel.
 */
internal object PhoneNumberMatcher {
    data class Span(val start: Int, val end: Int)

    fun spans(original: String): List<Span> {
        val text = original.map { c ->
            when {
                c in '\uFF01'..'\uFF5E' -> (c.code - 0xFEE0).toChar()
                c == '\u3000' || c == '\u00A0' || c == '\t' -> ' '
                c in "‐‑‒–—―−ー" -> '-'
                else -> c
            }
        }.joinToString("")
        val result = mutableListOf<Span>()
        var start = 0
        while (start < text.length) {
            val c = text[start]
            val isStart = c == '0' || c == '+' || (c == '(' && text.getOrNull(start + 1) == '0')
            val previous = text.getOrNull(start - 1)
            val prefix = text.substring(maxOf(0, start - 12), start)
            val afterLabel = Regex("(?i)(?:^|[^A-Za-z])(?:TEL|PHONE|FAX)$").containsMatchIn(prefix)
            val afterCountry = Regex("\\+[0-9]{1,3}[ -]*$").containsMatchIn(prefix)
            if (!isStart || afterCountry ||
                (previous != null && (word(previous) || previous in "-+.(") && !afterLabel)) {
                start++
                continue
            }
            var best = -1
            for (end in start until minOf(text.length, start + 48)) {
                val next = text[end]
                if (!(next in '0'..'9' || next in " ()-" || (next == '+' && end == start))) break
                if ((next in '0'..'9' || next == ')') &&
                    valid(text.substring(start, end + 1)) && boundary(text, end + 1)) best = end + 1
            }
            if (best > start) {
                result.add(Span(start, best))
                start = best
            } else start++
        }
        return result
    }

    private fun word(c: Char) = c in '0'..'9' || c in 'a'..'z' || c in 'A'..'Z' || c == '_'

    private fun boundary(text: String, end: Int): Boolean {
        val next = text.getOrNull(end) ?: return true
        if (word(next) || next == '+') return false
        // Never take a valid-looking prefix of a longer hyphenated identifier.
        if (next == '-' || next == '.') {
            var i = end + 1
            while (text.getOrNull(i) == ' ') i++
            if (text.getOrNull(i)?.let { it in '0'..'9' } == true) return false
        }
        return true
    }

    private fun valid(raw: String): Boolean {
        var depth = 0
        for (c in raw) {
            if (c == '(') depth++
            if (c == ')') depth--
            if (depth !in 0..1) return false
        }
        if (depth != 0) return false
        var compact = raw.replace(" ", "").replace("-", "")
        val international = compact.startsWith("+81")
        if (international) compact = compact.removePrefix("+81").removePrefix("(0)")
        compact = compact.replace("(", "").replace(")", "")
        if (compact.any { it !in '0'..'9' }) return false
        if (international) {
            if (compact.startsWith("0")) return false
            compact = "0$compact"
        }
        return if (compact.length == 11) {
            compact.startsWith("050") || compact.startsWith("070") || compact.startsWith("080") || compact.startsWith("090")
        } else compact.length == 10 && compact.startsWith("0") && compact[1] in '1'..'9' &&
            listOf("050", "070", "080", "090").none { compact.startsWith(it) }
    }
}
