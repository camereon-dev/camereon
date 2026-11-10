import 'package:flutter/services.dart';

import 'photo_images.dart';

/// Hands a saved, already-redacted JPEG to other apps right after saving.
abstract interface class PhotoSharer {
  /// Opens the system share sheet (X, messages, "Save to Files", ...).
  /// Returns false when nothing could be shown.
  Future<bool> share(RedactedJpeg jpeg);

  /// Opens the saved photo in the photo viewer (Android) or the Photos app
  /// (iOS, which cannot open one specific photo). Returns false on failure.
  Future<bool> open();
}

/// Android shares/opens the image it just added to MediaStore; iOS shares
/// the same flattened JPEG bytes from a temporary file. Only the redacted
/// output is ever handed over, never the original photo.
class PlatformPhotoSharer implements PhotoSharer {
  PlatformPhotoSharer({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.camereon/photo_share');

  final MethodChannel _channel;

  @override
  Future<bool> share(RedactedJpeg jpeg) =>
      _call('share', {'bytes': jpeg.bytes});

  @override
  Future<bool> open() => _call('open', const {});

  Future<bool> _call(String method, Map<String, Object> arguments) async {
    try {
      return await _channel.invokeMethod<bool>(method, arguments) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
