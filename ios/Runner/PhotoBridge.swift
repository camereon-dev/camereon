import Flutter
import ImageIO
import Photos
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Only rendered pixels enter Flutter; only flattened JPEG data leaves it.
final class PhotoBridge: NSObject, PHPickerViewControllerDelegate {
  private var pendingPick: FlutterResult?
  private var saving = false
  private let worker = DispatchQueue(label: "dev.camereon.photo", qos: .userInitiated)

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    FlutterMethodChannel(name: "dev.camereon/photo_picker", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "pick" else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.pick(result)
      }
    FlutterMethodChannel(name: "dev.camereon/photo_saver", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "save" else {
          result(FlutterMethodNotImplemented)
          return
        }
        guard let bytes = (call.arguments as? [String: Any])?["bytes"] as? FlutterStandardTypedData
        else {
          result("failed")
          return
        }
        self?.save(bytes.data, result: result)
      }
    // Also exercised by device tests with oriented/HEIC inputs.
    FlutterMethodChannel(name: "dev.camereon/image_normalizer", binaryMessenger: messenger)
      .setMethodCallHandler { [weak self] call, result in
        guard call.method == "normalize", let bytes = call.arguments as? FlutterStandardTypedData
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.worker.async {
          do {
            let data = try Self.normalize(bytes.data)
            DispatchQueue.main.async { result(FlutterStandardTypedData(bytes: data)) }
          } catch {
            DispatchQueue.main.async { result(Self.failure()) }
          }
        }
      }
  }

  private static func failure() -> FlutterError {
    FlutterError(code: "failed", message: "写真を処理できませんでした。静止画・25メガピクセル以内の写真を選んでください。", details: nil)
  }

  private func pick(_ result: @escaping FlutterResult) {
    guard pendingPick == nil else {
      result(FlutterError(code: "busy", message: "写真を選択中です", details: nil))
      return
    }
    guard
      var presenter = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).flatMap({ $0.windows })
        .first(where: { $0.isKeyWindow })?.rootViewController
    else {
      result(Self.failure())
      return
    }
    while let presented = presenter.presentedViewController { presenter = presented }
    pendingPick = result
    var configuration = PHPickerConfiguration()
    configuration.filter = .images
    configuration.selectionLimit = 1
    configuration.preferredAssetRepresentationMode = .current
    let picker = PHPickerViewController(configuration: configuration)
    picker.delegate = self
    presenter.present(picker, animated: true)
  }

  func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
    picker.dismiss(animated: true)
    guard let item = results.first?.itemProvider else {
      finishPick(nil)
      return
    }
    // Provider's temporary URL exists only during this callback; consume it here.
    item.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) {
      [weak self] url, error in
      guard let self else { return }
      do {
        guard error == nil, let url,
          let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
          size > 0, size <= 128 * 1024 * 1024
        else { throw PhotoError.invalid }
        let normalized = try autoreleasepool {
          try Self.normalize(Data(contentsOf: url, options: .mappedIfSafe))
        }
        DispatchQueue.main.async { self.finishPick(FlutterStandardTypedData(bytes: normalized)) }
      } catch {
        DispatchQueue.main.async { self.finishPick(Self.failure()) }
      }
    }
  }

  private func finishPick(_ value: Any?) {
    let callback = pendingPick
    pendingPick = nil
    callback?(value)
  }

  enum PhotoError: Error { case invalid }

  static func normalize(_ data: Data) throws -> Data {
    guard !data.isEmpty, data.count <= 128 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 25_000_000 / height
    else { throw PhotoError.invalid }
    let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
    guard (1...8).contains(orientation),
      let decoded = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: max(width, height),
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary),
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
      let context = CGContext(
        data: nil, width: decoded.width, height: decoded.height,
        bitsPerComponent: 8, bytesPerRow: decoded.width * 4, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw PhotoError.invalid }
    let bounds = CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height)
    context.setFillColor(UIColor.white.cgColor)
    context.fill(bounds)
    context.draw(decoded, in: bounds)
    guard let clean = context.makeImage() else { throw PhotoError.invalid }
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, UTType.png.identifier as CFString, 1, nil)
    else {
      throw PhotoError.invalid
    }
    CGImageDestinationAddImage(destination, clean, nil)
    guard CGImageDestinationFinalize(destination) else { throw PhotoError.invalid }
    return output as Data
  }

  private func save(_ bytes: Data, result: @escaping FlutterResult) {
    guard !saving, bytes.count >= 4, bytes.count <= 128 * 1024 * 1024,
      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
      CGImageSourceGetCount(source) == 1,
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      width > 0, height > 0, width <= 25_000_000 / height
    else {
      result("failed")
      return
    }
    saving = true
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] status in
      guard status == .authorized else {
        DispatchQueue.main.async {
          self?.saving = false
          result("permissionDenied")
        }
        return
      }
      PHPhotoLibrary.shared().performChanges({
        let request = PHAssetCreationRequest.forAsset()
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = "camereon_\(UUID().uuidString).jpg"
        options.uniformTypeIdentifier = UTType.jpeg.identifier
        // New asset, with exactly one resource. Never attach the input or adjustment data.
        request.addResource(with: .photo, data: bytes, options: options)
      }) { success, _ in
        DispatchQueue.main.async {
          self?.saving = false
          result(success ? "saved" : "failed")
        }
      }
    }
  }
}
