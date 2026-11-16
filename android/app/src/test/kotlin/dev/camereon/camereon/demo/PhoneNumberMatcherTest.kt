package dev.camereon.camereon.demo

import org.junit.Assert.assertEquals
import org.junit.Test

class PhoneNumberMatcherTest {
    @Test fun japanesePhoneRangesExcludeOtherTextAndNumericIdentifiers() {
        val resource = checkNotNull(javaClass.getResourceAsStream("/phone_numbers.tsv"))
        resource.bufferedReader().useLines { lines ->
            lines.forEach { row ->
                val fields = row.split('\t')
                val text = fields[1]
                val expected = if (fields[2] == "-") emptyList() else fields[2].split('|')
                val actual = PhoneNumberMatcher.spans(text).map { text.substring(it.start, it.end) }
                assertEquals(fields[0], expected, actual)
            }
        }
    }
}
