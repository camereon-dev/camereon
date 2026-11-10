import Foundation

/// Run with the production implementation, without requiring an iPhone:
/// swiftc ios/Runner/TextGeometry.swift scripts/test-ios-geometry.swift -o /tmp/camereon-geometry-tests
/// /tmp/camereon-geometry-tests
@main struct GeometryChecks {
  static func main() {
    for slope in [-0.6, 0.6] {
      let w = 160
      let h = 140
      var p = [Float](repeating: 0, count: w * h)
      var indices: [Int] = []
      for y in 0..<h {
        for x in 10...140 where abs(Double(y) - (70 + slope * Double(x - 75))) <= 4 {
          p[y * w + x] = 0.95
          indices.append(y * w + x)
        }
      }
      let top = indices.map { $0 / w }.min()!
      let bottom = indices.map { $0 / w }.max()!
      let geometry = TextGeometry.component(indices[...], width: w, top: top, bottom: bottom)
      precondition(
        geometry.score(p, width: w, left: 10, top: top, right: 140, bottom: bottom) > 0.85)
      let outline = TextGeometry.extremes(
        indices[...], width: w, top: top, bottom: bottom, corners: true)
      let grown = TextGeometry.grown(outline, margin: 4)
      precondition(grown.map(\.x).min()! < outline.map(\.x).min()!)
      precondition(grown.map(\.x).max()! > outline.map(\.x).max()!)
    }
    // A hollow frame must not get the high score of its boundary alone.
    let w = 40
    var p = [Float](repeating: 0, count: w * w)
    var border: [Int] = []
    for y in 5...34 {
      for x in 5...34 where x == 5 || x == 34 || y == 5 || y == 34 {
        p[y * w + x] = 0.95
        border.append(y * w + x)
      }
    }
    let geometry = TextGeometry.component(border[...], width: w, top: 5, bottom: 34)
    precondition(geometry.score(p, width: w, left: 5, top: 5, right: 34, bottom: 34) < 0.2)
    precondition(
      TextGeometry.hull([
        DetectionPoint(x: 0, y: 0), DetectionPoint(x: 1, y: 0), DetectionPoint(x: 0, y: 1),
        DetectionPoint(x: 0, y: 0),
      ]).count == 3)
    print("iOS text geometry checks passed")
  }
}
