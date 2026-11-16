import Foundation

// swiftc ios/Runner/PhoneNumberMatcher.swift scripts/test-ios-phone-matcher.swift -o /tmp/camereon-phone-check
// /tmp/camereon-phone-check android/app/src/test/resources/phone_numbers.tsv
@main struct PhoneChecks {
  static func main() throws {
    let rows = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
      .split(separator: "\n")
    for row in rows {
      let fields = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      let original = fields[1]
      let actual = PhoneNumberMatcher.ranges(in: original).map { (original as NSString).substring(with: $0) }
      let expected = fields[2] == "-" ? [] : fields[2].split(separator: "|").map(String.init)
      precondition(actual == expected, "Phone matching failed: \(fields[0])")
    }
    print("iOS phone matcher: \(rows.count) shared cases passed")
  }
}
