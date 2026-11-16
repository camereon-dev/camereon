import Foundation

/// Same Japanese-number rules and UTF-16 offsets as Android's PhoneNumberMatcher.
/// Recognition is temporary; only phone geometry is returned to Flutter.
enum PhoneNumberMatcher {
  static func ranges(in original: String) -> [NSRange] {
    let units: [UInt16] = original.utf16.map { value in
      if (0xFF01...0xFF5E).contains(value) { return value - 0xFEE0 }
      if [0x3000, 0x00A0, 9].contains(value) { return 32 }
      if Array("‐‑‒–—―−ー".utf16).contains(value) { return 45 }
      return value
    }
    var result: [NSRange] = []
    var start = 0
    while start < units.count {
      let c = units[start]
      let begins = c == 48 || c == 43 || (c == 40 && start + 1 < units.count && units[start + 1] == 48)
      let prefix = String(decoding: units[max(0, start - 12)..<start], as: UTF16.self)
      let afterLabel = prefix.range(of: "(?i)(?:^|[^A-Za-z])(?:TEL|PHONE|FAX)$", options: .regularExpression) != nil
      let afterCountry = prefix.range(of: "\\+[0-9]{1,3}[ -]*$", options: .regularExpression) != nil
      if !begins || afterCountry || (start > 0 && (word(units[start - 1]) || [45, 43, 46, 40].contains(units[start - 1])) && !afterLabel) {
        start += 1
        continue
      }
      var best: Int?
      for end in start..<min(units.count, start + 48) {
        let next = units[end]
        if !(digit(next) || [32, 40, 41, 45].contains(next) || (next == 43 && end == start)) { break }
        if (digit(next) || next == 41)
          && valid(String(decoding: units[start...end], as: UTF16.self))
          && boundary(units, end + 1) { best = end + 1 }
      }
      if let best {
        result.append(NSRange(location: start, length: best - start))
        start = best
      } else { start += 1 }
    }
    return result
  }

  private static func digit(_ c: UInt16) -> Bool { (48...57).contains(c) }
  private static func word(_ c: UInt16) -> Bool {
    digit(c) || (65...90).contains(c) || (97...122).contains(c) || c == 95
  }
  private static func boundary(_ units: [UInt16], _ end: Int) -> Bool {
    if end == units.count { return true }
    let next = units[end]
    if word(next) || next == 43 { return false }
    if next == 45 || next == 46 {
      var i = end + 1
      while i < units.count && units[i] == 32 { i += 1 }
      if i < units.count && digit(units[i]) { return false }
    }
    return true
  }
  private static func valid(_ raw: String) -> Bool {
    var depth = 0
    for c in raw {
      if c == "(" { depth += 1 }
      if c == ")" { depth -= 1 }
      if !(0...1).contains(depth) { return false }
    }
    if depth != 0 { return false }
    var compact = raw.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
    let international = compact.hasPrefix("+81")
    if international {
      compact.removeFirst(3)
      if compact.hasPrefix("(0)") { compact.removeFirst(3) }
    }
    compact = compact.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
    if compact.utf16.contains(where: { !digit($0) }) { return false }
    if international {
      if compact.hasPrefix("0") { return false }
      compact = "0" + compact
    }
    let mobile = ["050", "070", "080", "090"].contains(where: { compact.hasPrefix($0) })
    if compact.count == 11 { return mobile }
    let digits = Array(compact.utf16)
    return digits.count == 10 && digits[0] == 48 && (49...57).contains(digits[1]) && !mobile
  }
}
