import CoreGraphics
import Foundation
import Vision

/// Apple Vision OCR runs locally. Recognized strings never cross the platform channel.
final class PhoneRegionDetector {
  func detect(_ image: PixelImage) throws -> (boxes: [[Double]], truncated: Bool) {
    guard let provider = CGDataProvider(data: Data(image.bytes) as CFData),
      let cg = CGImage(
        width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { throw DetectionError() }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["en-US"]
    request.usesLanguageCorrection = false
    try VNImageRequestHandler(cgImage: cg).perform([request])
    var boxes: [[Double]] = []
    for observation in request.results ?? [] {
      guard let text = observation.topCandidates(1).first else { continue }
      for span in PhoneNumberMatcher.ranges(in: text.string) {
        guard let range = Range(span, in: text.string),
          let position = try text.boundingBox(for: range)
        else { continue }
        let r = position.boundingBox
        let width = Double(image.width), height = Double(image.height)
        let pad = min(3.0, max(1.0, r.height * height * 0.06))
        let box = [
          max(0, r.minX * width - pad), max(0, (1 - r.maxY) * height - pad),
          min(width, r.maxX * width + pad), min(height, (1 - r.minY) * height + pad),
        ]
        if !boxes.contains(box) { boxes.append(box) }
        if boxes.count > 100 { return (Array(boxes.prefix(100)), true) }
      }
    }
    return (boxes, false)
  }
}
