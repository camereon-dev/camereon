import Foundation

struct DetectionPoint: Hashable {
  let x: Double
  let y: Double
}

/// Port of Android TextBoxGeometry: score background inside a minimum-area box,
/// and grow the component hull rather than replacing tilted text by a rectangle.
struct TextGeometry {
  let cosine: Double, sine: Double
  let minU: Double, maxU: Double, minV: Double, maxV: Double
  var width: Double { maxU - minU + 1 }
  var height: Double { maxV - minV + 1 }

  func score(_ p: [Float], width: Int, left: Int, top: Int, right: Int, bottom: Int) -> Double {
    var sum = 0.0
    var count = 0
    for y in top...bottom {
      for x in left...right {
        let u = Double(x) * cosine + Double(y) * sine
        let v = -Double(x) * sine + Double(y) * cosine
        if u >= minU - 0.500001 && u <= maxU + 0.500001 && v >= minV - 0.500001
          && v <= maxV + 0.500001
        {
          sum += Double(p[y * width + x])
          count += 1
        }
      }
    }
    return count == 0 ? 0 : sum / Double(count)
  }

  static func hull(_ input: [DetectionPoint]) -> [DetectionPoint] {
    let points = Set(input).sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
    if points.count < 3 { return points }
    func half(_ points: [DetectionPoint]) -> [DetectionPoint] {
      var chain: [DetectionPoint] = []
      for p in points {
        while chain.count >= 2 {
          let a = chain[chain.count - 2]
          let b = chain[chain.count - 1]
          if (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) > 0 { break }
          chain.removeLast()
        }
        chain.append(p)
      }
      return Array(chain.dropLast())
    }
    return half(points) + half(points.reversed())
  }

  static func grown(_ polygon: [DetectionPoint], margin: Double) -> [DetectionPoint] {
    guard polygon.count >= 3, margin > 0 else { return polygon }
    var extra: [DetectionPoint] = []
    for i in polygon.indices {
      let a = polygon[i]
      let b = polygon[(i + 1) % polygon.count]
      let dx = b.x - a.x
      let dy = b.y - a.y
      let length = hypot(dx, dy)
      if length == 0 { continue }
      let nx = dy / length * margin
      let ny = -dx / length * margin
      extra.append(DetectionPoint(x: a.x + nx, y: a.y + ny))
      extra.append(DetectionPoint(x: b.x + nx, y: b.y + ny))
    }
    return hull(extra.isEmpty ? polygon : extra)
  }

  static func extremes(_ indices: ArraySlice<Int>, width: Int, top: Int, bottom: Int, corners: Bool)
    -> [DetectionPoint]
  {
    var left = [Int](repeating: Int.max, count: bottom - top + 1)
    var right = [Int](repeating: -1, count: left.count)
    for index in indices {
      let row = index / width - top
      let x = index % width
      left[row] = min(left[row], x)
      right[row] = max(right[row], x)
    }
    var points: [DetectionPoint] = []
    for row in left.indices where right[row] >= 0 {
      let y = Double(top + row)
      let l = Double(left[row])
      let r = Double(right[row])
      points.append(DetectionPoint(x: l, y: y))
      points.append(DetectionPoint(x: corners ? r + 1 : r, y: y))
      if corners {
        points.append(DetectionPoint(x: l, y: y + 1))
        points.append(DetectionPoint(x: r + 1, y: y + 1))
      }
    }
    return hull(points)
  }

  static func component(_ indices: ArraySlice<Int>, width: Int, top: Int, bottom: Int)
    -> TextGeometry
  {
    let points = extremes(indices, width: width, top: top, bottom: bottom, corners: false)
    if points.count < 2 {
      let p = points[0]
      return TextGeometry(cosine: 1, sine: 0, minU: p.x, maxU: p.x, minV: p.y, maxV: p.y)
    }
    var best: TextGeometry?
    var area = Double.infinity
    for i in points.indices {
      let a = points[i]
      let b = points[(i + 1) % points.count]
      let dx = b.x - a.x
      let dy = b.y - a.y
      let length = hypot(dx, dy)
      if length == 0 { continue }
      let co = dx / length
      let si = dy / length
      var minU = Double.infinity
      var maxU = -Double.infinity
      var minV = Double.infinity
      var maxV = -Double.infinity
      for p in points {
        let u = p.x * co + p.y * si
        let v = -p.x * si + p.y * co
        minU = min(minU, u)
        maxU = max(maxU, u)
        minV = min(minV, v)
        maxV = max(maxV, v)
      }
      let next = (maxU - minU) * (maxV - minV)
      if next < area - 1e-8 {
        best = TextGeometry(cosine: co, sine: si, minU: minU, maxU: maxU, minV: minV, maxV: maxV)
        area = next
      }
    }
    return best!
  }
}
