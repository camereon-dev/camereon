import Accelerate
import CryptoKit
import Flutter
import Foundation

struct DetectionError: Error {}

struct PixelImage {
  let bytes: [UInt8]
  let width: Int
  let height: Int

  init(_ arguments: [String: Any], limit: Int) throws {
    guard let data = arguments["bytes"] as? FlutterStandardTypedData,
      let w = arguments["width"] as? Int, let h = arguments["height"] as? Int,
      w > 0, h > 0, w <= limit, h <= limit, data.data.count == w * h * 4
    else { throw DetectionError() }
    bytes = Array(data.data)
    width = w
    height = h
  }
  init(bytes: [UInt8], width: Int, height: Int) {
    self.bytes = bytes
    self.width = width
    self.height = height
  }

  func resized(_ w: Int, _ h: Int) throws -> PixelImage {
    if w == width && h == height { return self }
    var output = [UInt8](repeating: 0, count: w * h * 4)
    let error = bytes.withUnsafeBytes { input in
      output.withUnsafeMutableBytes { out in
        var source = vImage_Buffer(
          data: UnsafeMutableRawPointer(mutating: input.baseAddress!),
          height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
        var target = vImage_Buffer(
          data: out.baseAddress!, height: vImagePixelCount(h), width: vImagePixelCount(w),
          rowBytes: w * 4)
        return vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageNoFlags))
      }
    }
    guard error == kvImageNoError else { throw DetectionError() }
    return PixelImage(bytes: output, width: w, height: h)
  }

  func cropped(x: Int, y: Int, width w: Int, height h: Int) -> PixelImage {
    var output = [UInt8](repeating: 0, count: w * h * 4)
    for row in 0..<h {
      let from = ((y + row) * width + x) * 4
      output.replaceSubrange(row * w * 4..<(row + 1) * w * 4, with: bytes[from..<from + w * 4])
    }
    return PixelImage(bytes: output, width: w, height: h)
  }
}

/// Accessed only on DetectionBridge's serial inference queue, including release.
final class DetectionRuntime {
  private var environment: ORTEnv?
  private var sessions: [String: ORTSession] = [:]

  func release() {
    sessions.removeAll()
    environment = nil
  }

  func session(_ directory: String) throws -> ORTSession {
    if let cached = sessions[directory] { return cached }
    let root = Bundle.main.bundleURL.appendingPathComponent("assets/\(directory)")
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("model.json"))) as? [String: Any]
    guard let file = manifest?["file"] as? String, !file.contains("/"),
      let expected = manifest?["sha256"] as? String
    else { throw DetectionError() }
    let model = root.appendingPathComponent(file)
    let digest = SHA256.hash(data: try Data(contentsOf: model, options: .mappedIfSafe))
      .map { String(format: "%02x", $0) }.joined()
    guard digest == expected else { throw DetectionError() }
    if environment == nil { environment = try ORTEnv(loggingLevel: .warning) }
    let options = try ORTSessionOptions()
    try options.setIntraOpNumThreads(
      Int32(min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 1))))
    let session = try ORTSession(env: environment!, modelPath: model.path, sessionOptions: options)
    sessions[directory] = session
    return session
  }

  func run(_ session: ORTSession, input: [Float], width: Int, height: Int) throws -> [[String: Any]]
  {
    let data = input.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
    let tensor = try ORTValue(
      tensorData: data, elementType: .float,
      shape: [1, 3, NSNumber(value: height), NSNumber(value: width)])
    let inputs = try session.inputNames()
    let names = try session.outputNames()
    guard let name = inputs.first else { throw DetectionError() }
    let options = try ORTRunOptions()
    try options.addConfigEntry(withKey: "memory.enable_memory_arena_shrinkage", value: "cpu:0")
    let outputs = try session.run(
      withInputs: [name: tensor], outputNames: Set(names), runOptions: options)
    return try names.map { name in
      guard let value = outputs[name] else { throw DetectionError() }
      let info = try value.tensorTypeAndShapeInfo()
      let data = try value.tensorData()
      guard data.length % MemoryLayout<Float>.stride == 0 else { throw DetectionError() }
      let floats = Array(
        UnsafeBufferPointer(
          start: data.bytes.assumingMemoryBound(to: Float.self),
          count: data.length / MemoryLayout<Float>.stride))
      return ["shape": info.shape.map { $0.intValue }, "values": floats]
    }
  }
}
