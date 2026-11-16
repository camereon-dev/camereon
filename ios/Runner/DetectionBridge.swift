import Flutter
import ImageIO
import MLKitFaceDetection
import MLKitTextRecognition
import MLKitTextRecognitionJapanese
import MLKitVision
import UIKit

/// All expensive work is serialized; a memory warning queues release after the
/// active call, never invalidating a session while ONNX Runtime is using it.
final class DetectionBridge {
  private let worker = DispatchQueue(label: "dev.camereon.detection", qos: .userInitiated)
  private let runtime = DetectionRuntime()
  private var busy = Set<String>()  // Main-thread only.
  private var memoryObserver: NSObjectProtocol?

  init(messenger: FlutterBinaryMessenger) {
    for kind in ["face_detection", "text_regions", "object_regions", "text_recognition"] {
      FlutterMethodChannel(name: "dev.camereon/\(kind)", binaryMessenger: messenger)
        .setMethodCallHandler { [weak self] call, result in
          guard let self else {
            result(FlutterError(code: "unavailable", message: "検出器を利用できません", details: nil))
            return
          }
          if call.method == "release" {
            self.worker.async {
              self.runtime.release()
              DispatchQueue.main.async { result(nil) }
            }
            return
          }
          guard call.method == "detect" || call.method == "recognize" else {
            result(FlutterMethodNotImplemented)
            return
          }
          guard let arguments = call.arguments as? [String: Any], !self.busy.contains(kind) else {
            result(FlutterError(code: "busy", message: "検出器を利用できません", details: nil))
            return
          }
          self.busy.insert(kind)
          self.worker.async {
            let response: Any
            do {
              response = try autoreleasepool { () -> Any in
                switch kind {
                case "face_detection": return try Self.faces(arguments)
                case "text_regions":
                  let detailed = arguments["detailed"] as? Bool ?? true
                  return try TextRegionDetector(runtime: self.runtime).detect(
                    PixelImage(arguments, limit: detailed ? 2560 : 960), detailed: detailed)
                case "text_recognition": return try Self.recognize(arguments)
                default:
                  return try ObjectRegionDetector(runtime: self.runtime).detect(
                    PixelImage(arguments, limit: 1600))
                }
              }
            } catch {
              response = FlutterError(
                code: "detectionFailed", message: "候補を検出できませんでした", details: nil)
            }
            DispatchQueue.main.async {
              self.busy.remove(kind)
              result(response)
            }
          }
        }
    }
    // ... rest of init ...
    memoryObserver = NotificationCenter.default.addObserver(
      forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      self.worker.async { self.runtime.release() }
    }
  }

  private static func recognize(_ arguments: [String: Any]) throws -> Any {
    guard let bytes = arguments["bytes"] as? FlutterStandardTypedData,
          let width = arguments["width"] as? Int, let height = arguments["height"] as? Int,
          let uiImage = UIImage(data: bytes.data) else { throw DetectionError() }

    let recognizer = TextRecognizer.textRecognizer(options: JapaneseTextRecognizerOptions())
    let image = VisionImage(image: uiImage)
    image.orientation = .up

    let text = try recognizer.results(in: image)
    return text.blocks.map { block in
        ["text": block.text,
         "box": [block.frame.minX, block.frame.minY, block.frame.maxX, block.frame.maxY]]
    }
  }
  // ... rest of class ...


  deinit {
    if let memoryObserver { NotificationCenter.default.removeObserver(memoryObserver) }
  }

  private static func faces(_ arguments: [String: Any]) throws -> [String: Any] {
    guard let bytes = arguments["bytes"] as? FlutterStandardTypedData,
      let width = arguments["width"] as? Int, let height = arguments["height"] as? Int,
      width > 0, height > 0, width <= 25_000_000 / height,
      bytes.data.count <= 128 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(bytes.data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      properties[kCGImagePropertyPixelWidth] as? Int == width,
      properties[kCGImagePropertyPixelHeight] as? Int == height,
      let cg = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1600,
        ] as CFDictionary)
    else { throw DetectionError() }
    let minFaceSize = arguments["minFaceSize"] as? Double ?? 0.02
    guard minFaceSize.isFinite, minFaceSize > 0, minFaceSize <= 1 else { throw DetectionError() }
    let options = FaceDetectorOptions()
    options.performanceMode = .accurate
    options.minFaceSize = CGFloat(minFaceSize)
    let detector = FaceDetector.faceDetector(options: options)
    let image = VisionImage(image: UIImage(cgImage: cg))
    image.orientation = .up
    let faces = try detector.results(in: image)
    return [
      "width": cg.width, "height": cg.height,
      "faces": faces.map { face in
        [face.frame.minX, face.frame.minY, face.frame.maxX, face.frame.maxY]
      },
    ]
  }
}
