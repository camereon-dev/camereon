import Foundation

final class TextRegionDetector {
  struct Found {
    let box: [Double]
    let outline: [DetectionPoint]
    func shifted(_ x: Int, _ y: Int) -> Found {
      Found(
        box: [box[0] + Double(x), box[1] + Double(y), box[2] + Double(x), box[3] + Double(y)],
        outline: outline.map { DetectionPoint(x: $0.x + Double(x), y: $0.y + Double(y)) })
    }
  }
  private let runtime: DetectionRuntime
  init(runtime: DetectionRuntime) { self.runtime = runtime }

  static func plan(_ length: Int) -> (Int, [Int]) {
    let count = max(1, Int(ceil(Double(length - 64) / 640)))
    if count == 1 { return (length, [0]) }
    let edge = Int(ceil(Double(length - 64) / Double(count))) + 64
    return (
      edge, (0..<count).map { Int((Double($0 * (length - edge)) / Double(count - 1)).rounded()) }
    )
  }

  func detect(_ image: PixelImage, detailed: Bool) throws -> [String: Any] {
    let start = Date()
    let cap = detailed ? 500 : 200
    let session = try runtime.session("text_detection")
    var merged: [Found] = []
    var truncated = false
    var passes = 1
    func include(_ found: Found) {
      if found.box[2] - found.box[0] < 8 && found.box[3] - found.box[1] < 8 { return }
      var box = found.box
      var outline = found.outline
      var index = 0
      while index < merged.count {
        let old = merged[index]
        if Self.duplicate(box, old.box) {
          box = [
            min(box[0], old.box[0]), min(box[1], old.box[1]), max(box[2], old.box[2]),
            max(box[3], old.box[3]),
          ]
          outline = TextGeometry.hull(outline + old.outline)
          merged.remove(at: index)
          index = 0
        } else {
          index += 1
        }
      }
      if merged.count < cap {
        merged.append(Found(box: box, outline: outline))
      } else {
        truncated = true
      }
    }
    let overview = try infer(
      image, side: detailed ? 1536 : 960, upscale: false, oriented: detailed, session: session)
    if !detailed || max(image.width, image.height) <= 960 {
      truncated = overview.count > cap
      merged = Array(overview.prefix(cap))
    } else {
      let (tw, xs) = Self.plan(image.width)
      let (th, ys) = Self.plan(image.height)
      guard xs.count <= 4, ys.count <= 4 else { throw DetectionError() }
      for y in ys {
        for x in xs {
          let found = try autoreleasepool {
            try infer(
              image.cropped(
                x: x, y: y, width: min(tw, image.width - x), height: min(th, image.height - y)),
              side: 1024, upscale: true, oriented: true, session: session)
          }
          for result in found {
            let mapped = result.shifted(x, y)
            if !overview.contains(where: { Self.largeLineFragment(mapped.box, $0.box) }) {
              include(mapped)
            }
          }
          passes += 1
        }
      }
      for found in overview {
        let b = found.box
        let fineLine = merged.contains { fine in
          Self.duplicate(fine.box, b)
            && min(fine.box[2] - fine.box[0], b[2] - b[0])
              / max(fine.box[2] - fine.box[0], b[2] - b[0]) >= 0.8
        }
        if !fineLine { include(found) }
      }
    }
    merged.sort { $0.box[1] == $1.box[1] ? $0.box[0] < $1.box[0] : $0.box[1] < $1.box[1] }
    return [
      "width": image.width, "height": image.height, "boxes": merged.map { $0.box },
      "polygons": merged.map { found in
        found.outline.flatMap {
          [min(Double(image.width), max(0, $0.x)), min(Double(image.height), max(0, $0.y))]
        }
      },
      "truncated": truncated, "passes": passes, "elapsedMs": Date().timeIntervalSince(start) * 1000,
    ]
  }

  private static func intersection(_ a: [Double], _ b: [Double]) -> Double {
    max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
  }
  static func duplicate(_ a: [Double], _ b: [Double]) -> Bool {
    let aw = a[2] - a[0]
    let ah = a[3] - a[1]
    let bw = b[2] - b[0]
    let bh = b[3] - b[1]
    let overlap = intersection(a, b)
    return overlap / (aw * ah + bw * bh - overlap) >= 0.45
      || (overlap / min(aw * ah, bw * bh) >= 0.8 && min(ah, bh) / max(ah, bh) >= 0.35
        && abs((a[1] + a[3] - b[1] - b[3]) / 2) <= min(ah, bh) * 0.5)
  }
  private static func largeLineFragment(_ a: [Double], _ b: [Double]) -> Bool {
    let aw = a[2] - a[0]
    let ah = a[3] - a[1]
    let bw = b[2] - b[0]
    let bh = b[3] - b[1]
    if min(bw, bh) < 48 || max(bw, bh) / min(bw, bh) < 2 { return false }
    let shorter = bw >= bh ? aw < bw * 0.9 || ah < bh * 0.6 : ah < bh * 0.9 || aw < bw * 0.6
    return shorter && intersection(a, b) / (aw * ah) >= 0.9
  }

  private func infer(
    _ image: PixelImage, side: Int, upscale: Bool, oriented: Bool, session: ORTSession
  ) throws -> [Found] {
    let scale =
      upscale
      ? Double(side) / Double(max(image.width, image.height))
      : min(1, Double(side) / Double(max(image.width, image.height)))
    let fw = max(1, Int((Double(image.width) * scale).rounded()))
    let fh = max(1, Int((Double(image.height) * scale).rounded()))
    let w = max(32, Int((Double(fw) / 32).rounded()) * 32)
    let h = max(32, Int((Double(fh) / 32).rounded()) * 32)
    let pixels = try image.resized(fw, fh).resized(w, h)
    let plane = w * h
    var input = [Float](repeating: 0, count: plane * 3)
    let means: [Float] = [0.485, 0.456, 0.406]
    let stds: [Float] = [0.229, 0.224, 0.225]
    for i in 0..<plane {
      for c in 0..<3 {
        input[c * plane + i] = (Float(pixels.bytes[i * 4 + 2 - c]) / 255 - means[c]) / stds[c]
      }
    }
    let outputs = try runtime.run(session, input: input, width: w, height: h)
    guard let first = outputs.first, let shape = first["shape"] as? [Int],
      shape.count == 4, shape[0] == 1, shape[1] == 1, shape[2] > 0, shape[3] > 0,
      let p = first["values"] as? [Float], p.count == shape[2] * shape[3],
      p.allSatisfy({ $0.isFinite })
    else { throw DetectionError() }
    return boxes(
      p, width: shape[3], height: shape[2], image: image, lineFilter: upscale, pixels: pixels,
      oriented: oriented)
  }

  private func hasContrast(
    _ pixels: PixelImage, left l: Int, top t: Int, right r: Int, bottom b: Int
  ) -> Bool {
    let left = min(pixels.width - 1, max(0, l))
    let top = min(pixels.height - 1, max(0, t))
    let right = min(pixels.width, max(left + 1, r))
    let bottom = min(pixels.height, max(top + 1, b))
    let sx = max(1, (right - left) / 32)
    let sy = max(1, (bottom - top) / 32)
    var low = [Int](repeating: 255, count: 3)
    var high = [Int](repeating: 0, count: 3)
    var plow = low
    var phigh = high
    let vertical = bottom - top > right - left
    for outer in stride(
      from: vertical ? top : left, to: vertical ? bottom : right, by: vertical ? sy : sx)
    {
      var sums = [Int](repeating: 0, count: 3)
      var count = 0
      for inner in stride(
        from: vertical ? left : top, to: vertical ? right : bottom, by: vertical ? sx : sy)
      {
        let x = vertical ? inner : outer
        let y = vertical ? outer : inner
        for c in 0..<3 {
          let value = Int(pixels.bytes[(y * pixels.width + x) * 4 + c])
          low[c] = min(low[c], value)
          high[c] = max(high[c], value)
          sums[c] += value
        }
        count += 1
      }
      for c in 0..<3 {
        let mean = sums[c] / count
        plow[c] = min(plow[c], mean)
        phigh[c] = max(phigh[c], mean)
        if high[c] - low[c] >= 12 && phigh[c] - plow[c] >= 4 { return true }
      }
    }
    return false
  }

  private func boxes(
    _ p: [Float], width: Int, height: Int, image: PixelImage, lineFilter: Bool, pixels: PixelImage,
    oriented: Bool
  ) -> [Found] {
    var visited = [Bool](repeating: false, count: p.count)
    var queue = [Int](repeating: 0, count: p.count)
    var found: [Found] = []
    for seed in p.indices {
      if visited[seed] || p[seed] < 0.3 { continue }
      var head = 0
      var tail = 1
      var left = width
      var right = 0
      var top = height
      var bottom = 0
      queue[0] = seed
      visited[seed] = true
      while head < tail {
        let index = queue[head]
        let x = index % width
        let y = index / width
        head += 1
        left = min(left, x)
        right = max(right, x)
        top = min(top, y)
        bottom = max(bottom, y)
        for next in [
          x > 0 ? index - 1 : -1, x + 1 < width ? index + 1 : -1, y > 0 ? index - width : -1,
          y + 1 < height ? index + width : -1,
        ] {
          if next >= 0 && !visited[next] && p[next] >= 0.3 {
            visited[next] = true
            queue[tail] = next
            tail += 1
          }
        }
      }
      let w = right - left + 1
      let h = bottom - top + 1
      if min(w, h) < 3 { continue }
      let component = queue.prefix(tail)
      let geometry =
        oriented ? TextGeometry.component(component, width: width, top: top, bottom: bottom) : nil
      let tw = geometry?.width ?? Double(w)
      let th = geometry?.height ?? Double(h)
      if min(tw, th) < 3 { continue }
      let score: Double
      if let geometry {
        score = geometry.score(p, width: width, left: left, top: top, right: right, bottom: bottom)
      } else {
        var sum = 0.0
        for y in top...bottom { for x in left...right { sum += Double(p[y * width + x]) } }
        score = sum / Double(w * h)
      }
      if score < 0.6 { continue }
      if lineFilter && max(tw, th) / min(tw, th) < 1.5 && score < 0.75 { continue }
      let margin = tw * th * 1.5 / (2 * (tw + th))
      if lineFilter
        && !hasContrast(
          pixels,
          left: Int((Double(left) - margin) * Double(pixels.width) / Double(width)),
          top: Int((Double(top) - margin) * Double(pixels.height) / Double(height)),
          right: Int(ceil((Double(right + 1) + margin) * Double(pixels.width) / Double(width))),
          bottom: Int(ceil((Double(bottom + 1) + margin) * Double(pixels.height) / Double(height))))
      {
        continue
      }
      let sx = Double(image.width) / Double(width)
      let sy = Double(image.height) / Double(height)
      let box = [
        max(0, Double(left) - margin) * sx, max(0, Double(top) - margin) * sy,
        min(Double(width), Double(right + 1) + margin) * sx,
        min(Double(height), Double(bottom + 1) + margin) * sy,
      ]
      let outline: [DetectionPoint]
      if geometry == nil {
        outline = [
          DetectionPoint(x: box[0], y: box[1]), DetectionPoint(x: box[2], y: box[1]),
          DetectionPoint(x: box[2], y: box[3]), DetectionPoint(x: box[0], y: box[3]),
        ]
      } else {
        outline = TextGeometry.grown(
          TextGeometry.extremes(component, width: width, top: top, bottom: bottom, corners: true),
          margin: margin
        )
        .map { DetectionPoint(x: $0.x * sx, y: $0.y * sy) }
      }
      found.append(Found(box: box, outline: outline))
    }
    return found.sorted { $0.box[1] == $1.box[1] ? $0.box[0] < $1.box[0] : $0.box[1] < $1.box[1] }
  }
}
