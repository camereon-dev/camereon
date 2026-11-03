import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// How the phone is physically held, from the accelerometer, as the clockwise
/// degrees (0, 90, 180 or 270) content must turn to look upright: [value] is
/// relative to the device's natural orientation (what capture needs) and
/// [uiDegrees] relative to the screen as drawn (what icons need).
///
/// The screen is portrait-locked, so the camera plugin's orientation (taken
/// from the display) is always portrait.
class DeviceRotation extends ValueNotifier<int> {
  DeviceRotation({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.camereon/device_rotation'),
      super(0) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') _set(call.arguments);
    });
    // Unavailable (tests, devices without a sensor) simply stays upright.
    _channel.invokeMethod<Object?>('current').then(_set, onError: (_) {});
  }

  final MethodChannel _channel;
  bool _disposed = false;
  int uiDegrees = 0;

  void _set(Object? message) {
    if (_disposed || message is! Map) return;
    final capture = message['capture'];
    final ui = message['ui'];
    if (capture is! int || ui is! int || capture % 90 != 0 || ui % 90 != 0) {
      return;
    }
    uiDegrees = ui % 360;
    if (value == capture % 360) {
      notifyListeners();
    } else {
      value = capture % 360;
    }
  }

  /// The capture orientation the camera plugin maps back to this rotation
  /// (portraitUp → 0, landscapeLeft → 90, portraitDown → 180,
  /// landscapeRight → 270), whatever the device's natural orientation.
  DeviceOrientation get captureOrientation => switch (value) {
    90 => DeviceOrientation.landscapeLeft,
    180 => DeviceOrientation.portraitDown,
    270 => DeviceOrientation.landscapeRight,
    _ => DeviceOrientation.portraitUp,
  };

  /// Turns for an icon so it stays upright: the shorter way round.
  double get iconTurns => switch (uiDegrees) {
    90 => .25,
    180 => .5,
    270 => -.25,
    _ => 0,
  };

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}
