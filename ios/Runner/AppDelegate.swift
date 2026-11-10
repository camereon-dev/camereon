import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var photos: PhotoBridge?
  private var detection: DetectionBridge?
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    photos = PhotoBridge(messenger: messenger)
    detection = DetectionBridge(messenger: messenger)
    FlutterMethodChannel(name: "dev.camereon/app_info", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "version" else {
          result(FlutterMethodNotImplemented)
          return
        }
        result([
          "versionName": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "",
          "versionCode": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "",
        ])
      }
    FlutterMethodChannel(name: "dev.camereon/app_settings", binaryMessenger: messenger)
      .setMethodCallHandler { call, result in
        guard call.method == "open", let url = URL(string: UIApplication.openSettingsURLString)
        else {
          result(FlutterMethodNotImplemented)
          return
        }
        UIApplication.shared.open(url) { opened in
          result(
            opened ? nil : FlutterError(code: "unavailable", message: "設定を開けませんでした", details: nil))
        }
      }
  }
}
