import Flutter
import Photos
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "dev.camereon/app_settings",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }

      guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else {
        result(FlutterError(code: "settings_unavailable", message: nil, details: nil))
        return
      }
      UIApplication.shared.open(settingsURL) { opened in
        if opened {
          result(nil)
        } else {
          result(FlutterError(code: "settings_unavailable", message: nil, details: nil))
        }
      }
    }

    let photoSaver = FlutterMethodChannel(
      name: "dev.camereon/photo_saver",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    var saveInProgress = false
    photoSaver.setMethodCallHandler { call, result in
      guard call.method == "save" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        !saveInProgress,
        let arguments = call.arguments as? [String: Any],
        let typedData = arguments["bytes"] as? FlutterStandardTypedData,
        typedData.data.count > 4
      else {
        result("failed")
        return
      }
      let imageData = typedData.data
      guard imageData.starts(with: [0xff, 0xd8]), imageData.suffix(2).elementsEqual([0xff, 0xd9]) else {
        result("failed")
        return
      }

      saveInProgress = true
      let finish: (String) -> Void = { status in
        DispatchQueue.main.async {
          saveInProgress = false
          result(status)
        }
      }
      let saveAuthorized: (PHAuthorizationStatus) -> Void = { status in
        guard status == .authorized || status == .limited else {
          finish(status == .denied || status == .restricted ? "permissionDenied" : "failed")
          return
        }
        PHPhotoLibrary.shared().performChanges {
          let request = PHAssetCreationRequest.forAsset()
          let options = PHAssetResourceCreationOptions()
          options.uniformTypeIdentifier = "public.jpeg"
          request.addResource(with: .photo, data: imageData, options: options)
        } completionHandler: { success, _ in
          finish(success ? "saved" : "failed")
        }
      }

      let authorization = PHPhotoLibrary.authorizationStatus(for: .addOnly)
      if authorization == .notDetermined {
        PHPhotoLibrary.requestAuthorization(for: .addOnly, handler: saveAuthorized)
      } else {
        saveAuthorized(authorization)
      }
    }
  }
}
