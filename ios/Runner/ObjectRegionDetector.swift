import Flutter
import Foundation

final class ObjectRegionDetector {
  private struct Pass {
    let proto: [Float]
    let width: Int, height: Int
    let scale: Double
    let left: Int, top: Int
  }
  private struct Box {
    let label: Int
    let score: Float
    let rect: [Double]
    let coefficients: [Float]
    let pass: Pass
    var kind: String {
      label == 0 ? "person" : [2, 3, 5, 7].contains(label) ? "vehicle" : "screen"
    }
    var area: Double { (rect[2] - rect[0]) * (rect[3] - rect[1]) }
    func redundant(with kept: Box) -> Bool {
      if kind != kept.kind { return false }
      let b = kept.rect
      let overlap =
        max(0, min(rect[2], b[2]) - max(rect[0], b[0]))
        * max(0, min(rect[3], b[3]) - max(rect[1], b[1]))
      return overlap / (area + kept.area - overlap) > 0.7
        || (kind == "vehicle" && overlap >= area * 0.8)
    }
  }
  private let runtime: DetectionRuntime
  init(runtime: DetectionRuntime) { self.runtime = runtime }

  func detect(_ image: PixelImage) throws -> [String: Any] {
    let start = Date()
    let session = try runtime.session("object_detection")
    var all: [Box] = []
    for side in [640, 1280] { all += try infer(image, side: side, session: session) }
    all.sort { $0.score > $1.score }
    var selected: [Box] = []
    for box in all {
      let r = box.rect
      if box.kind == "vehicle"
        && max(r[2] - r[0], r[3] - r[1]) < Double(max(image.width, image.height)) * 0.06
      {
        continue
      }
      if !selected.contains(where: { box.redundant(with: $0) }) { selected.append(box) }
    }
    selected.sort { $0.rect[1] == $1.rect[1] ? $0.rect[0] < $1.rect[0] : $0.rect[1] < $1.rect[1] }
    let candidates: [[String: Any]] = selected.prefix(200).map { box in
      ["kind": box.kind, "box": box.rect, "mask": mask(box, image: image)]
    }
    return [
      "width": image.width, "height": image.height, "candidates": candidates,
      "truncated": selected.count > 200, "elapsedMs": Date().timeIntervalSince(start) * 1000,
    ]
  }

  private func mask(_ box: Box, image: PixelImage) -> [String: Any] {
    let p = box.pass
    let b = box.rect
    let x1 = min(p.width - 1, max(0, Int(floor((b[0] * p.scale + Double(p.left)) / 4))))
    let y1 = min(p.height - 1, max(0, Int(floor((b[1] * p.scale + Double(p.top)) / 4))))
    let x2 = min(p.width, max(x1 + 1, Int(ceil((b[2] * p.scale + Double(p.left)) / 4))))
    let y2 = min(p.height, max(y1 + 1, Int(ceil((b[3] * p.scale + Double(p.top)) / 4))))
    let w = x2 - x1
    let h = y2 - y1
    let plane = p.width * p.height
    var bytes = [UInt8](repeating: 0, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        let cell = (y1 + y) * p.width + x1 + x
        var sum: Float = 0
        for k in 0..<32 { sum += box.coefficients[k] * p.proto[k * plane + cell] }
        bytes[y * w + x] = UInt8(min(255, max(0, Int((255 / (1 + exp(-Double(sum)))).rounded()))))
      }
    }
    return [
      "width": w, "height": h, "bytes": FlutterStandardTypedData(bytes: Data(bytes)),
      "left": min(Double(image.width), max(0, Double(x1 * 4 - p.left) / p.scale)),
      "top": min(Double(image.height), max(0, Double(y1 * 4 - p.top) / p.scale)),
      "right": min(Double(image.width), max(0, Double(x2 * 4 - p.left) / p.scale)),
      "bottom": min(Double(image.height), max(0, Double(y2 * 4 - p.top) / p.scale)),
    ]
  }

  private func infer(_ image: PixelImage, side: Int, session: ORTSession) throws -> [Box] {
    let scale = min(Double(side) / Double(image.width), Double(side) / Double(image.height))
    let rw = max(1, Int((Double(image.width) * scale).rounded()))
    let rh = max(1, Int((Double(image.height) * scale).rounded()))
    let pw = (side - rw) % 32
    let ph = (side - rh) % 32
    let w = rw + pw
    let h = rh + ph
    let left = Int((Double(pw) / 2 - 0.1).rounded())
    let top = Int((Double(ph) / 2 - 0.1).rounded())
    let pixels = try image.resized(rw, rh)
    let plane = w * h
    var input = [Float](repeating: 114.0 / 255.0, count: plane * 3)
    for y in 0..<rh {
      for x in 0..<rw {
        let source = (y * rw + x) * 4
        let target = (y + top) * w + x + left
        for c in 0..<3 { input[c * plane + target] = Float(pixels.bytes[source + c]) / 255 }
      }
    }
    let outputs = try runtime.run(session, input: input, width: w, height: h)
    guard outputs.count == 2,
      let shape = outputs[0]["shape"] as? [Int], shape.count == 3, shape[0] == 1, shape[1] <= 300,
      shape[2] == 38,
      let rows = outputs[0]["values"] as? [Float], rows.count == shape[1] * 38,
      let ps = outputs[1]["shape"] as? [Int], ps.count == 4, ps[0] == 1, ps[1] == 32, ps[2] > 0,
      ps[3] > 0,
      let proto = outputs[1]["values"] as? [Float], proto.count == 32 * ps[2] * ps[3],
      rows.allSatisfy({ $0.isFinite }), proto.allSatisfy({ $0.isFinite })
    else { throw DetectionError() }
    let pass = Pass(proto: proto, width: ps[3], height: ps[2], scale: scale, left: left, top: top)
    var found: [Box] = []
    let classes: [Float] = [0, 2, 3, 5, 7, 62, 63, 67]
    for i in 0..<shape[1] {
      let row = i * 38
      let score = rows[row + 4]
      let label = rows[row + 5]
      if score < 0.25 || !classes.contains(label) { continue }
      let l = min(Double(image.width), max(0, (Double(rows[row]) - Double(left)) / scale))
      let t = min(Double(image.height), max(0, (Double(rows[row + 1]) - Double(top)) / scale))
      let r = min(Double(image.width), max(0, (Double(rows[row + 2]) - Double(left)) / scale))
      let b = min(Double(image.height), max(0, (Double(rows[row + 3]) - Double(top)) / scale))
      if l < r && t < b {
        found.append(
          Box(
            label: Int(label), score: score, rect: [l, t, r, b],
            coefficients: Array(rows[row + 6..<row + 38]), pass: pass))
      }
    }
    return found
  }
}
