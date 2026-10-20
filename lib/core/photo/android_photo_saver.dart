import 'package:flutter/services.dart';

import 'photo_images.dart';
import 'photo_saver.dart';

class AndroidPhotoSaver implements PhotoSaver {
  const AndroidPhotoSaver({
    MethodChannel channel = const MethodChannel('dev.camereon/photo_saver'),
  }) : _channel = channel;

  final MethodChannel _channel;

  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
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
    }
  }
}
