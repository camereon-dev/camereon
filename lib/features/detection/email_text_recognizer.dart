import 'package:flutter/services.dart';

import '../../core/photo/hide_region.dart';
import '../../core/photo/photo_images.dart';

/// メールアドレスの自動認識とマスキングを行うための認識器。
/// 認識されたテキストはメモリ上での判定のみに使用する。
class EmailTextRecognizer {
  EmailTextRecognizer({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('dev.camereon/text_recognition');

  final MethodChannel _channel;
  bool _working = false;

  static final RegExp _emailRegExp = RegExp(
    r'[a-zA-Z0-9_.+\-]+@[a-zA-Z0-9\-]+\.[a-zA-Z0-9\-.]+',
  );

  /// 写真からテキストを認識し、メールアドレスと判定された領域を [HideRegion] として返す。
  Future<List<HideRegion>> detectEmailRegions(SourcePhoto photo) async {
    if (_working ||
        photo.width <= 0 ||
        photo.height <= 0 ||
        photo.bytes.isEmpty) {
      return const [];
    }
    _working = true;
    try {
      final result = await _channel.invokeMethod<List<dynamic>>('recognize', {
        'bytes': photo.bytes,
        'width': photo.width,
        'height': photo.height,
      });

      if (result == null) return const [];

      final emailRegions = <HideRegion>[];
      const padding = 6.0;

      for (final block in result) {
        if (block is! Map) continue;
        final text = block['text']?.toString() ?? '';
        final box = block['box'] as List?;
        if (box == null || box.length != 4) continue;

        if (_emailRegExp.hasMatch(text)) {
          final left = (box[0] as num).toDouble();
          final top = (box[1] as num).toDouble();
          final right = (box[2] as num).toDouble();
          final bottom = (box[3] as num).toDouble();

          final paddedRect = Rect.fromLTRB(
            left - padding,
            top - padding,
            right + padding,
            bottom + padding,
          );

          final region = HideRegion.fromRect(
            paddedRect,
            imageWidth: photo.width,
            imageHeight: photo.height,
          );
          if (region != null) {
            emailRegions.add(region);
          }
        }
      }
      return emailRegions;
    } catch (_) {
      return const [];
    } finally {
      _working = false;
    }
  }
}
// 認識されたテキストはここでの正規表現判定だけに使用し、
// 他への保存やログ出力は一切行わないため、メモリ破棄後に自動的にGCされる。
