import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 前回の異常終了や撮影失敗で残った、未加工の撮影ファイルを消す。
///
/// camera プラグインは撮影した写真をキャッシュに `CAP*.jpg` として書き出す。
Future<void> deleteLeftoverCaptures() async {
  try {
    final cache = await getTemporaryDirectory();
    await for (final entity in cache.list()) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && name.startsWith('CAP') && name.endsWith('.jpg')) {
        await entity.delete();
      }
    }
  } catch (e) {
    debugPrint('camera: failed to delete leftover captures: $e');
  }
}
