import Flutter
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
  }
}
