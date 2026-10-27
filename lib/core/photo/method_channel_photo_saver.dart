import 'package:flutter/services.dart';

import 'photo_images.dart';
import 'photo_saver.dart';

class MethodChannelPhotoSaver implements PhotoSaver {
  MethodChannelPhotoSaver({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.camereon/photo_saver');

  final MethodChannel _channel;
  bool _saving = false;

  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
    if (_saving || jpeg.bytes.isEmpty || jpeg.width <= 0 || jpeg.height <= 0) {
      return const SaveFailed(SaveFailureReason.failed);
    }
    _saving = true;
    try {
      final result = await _channel.invokeMethod<String>('save', {
        'bytes': jpeg.bytes,
      });
      return switch (result) {
        'saved' => const SaveSucceeded(),
        'permissionDenied' => const SaveFailed(
          SaveFailureReason.permissionDenied,
        ),
        _ => const SaveFailed(SaveFailureReason.failed),
      };
    } on PlatformException catch (error) {
      if (error.code == 'permissionDenied') {
        return const SaveFailed(SaveFailureReason.permissionDenied);
      }
      return const SaveFailed(SaveFailureReason.failed);
    } on MissingPluginException {
      return const SaveFailed(SaveFailureReason.failed);
    } finally {
      _saving = false;
    }
  }
}
