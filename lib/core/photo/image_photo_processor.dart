import 'dart:isolate';
import 'dart:typed_data';

import 'hide_region.dart';
import 'photo_images.dart';
import 'photo_processing_exception.dart';
import 'photo_processor.dart';
import 'src/photo_processing_worker.dart';

/// JPEG・静止 PNG を端末内で処理する。ディスク・画面・プラグインには依存しない。
///
/// 上限は暫定の保護値であり、端末のメモリ確保を保証するものではない。
/// 呼び出し側は重複操作を抑止する。キャンセルは提供しないため、画面破棄後や
/// 選択変更前の古い結果は呼び出し側で破棄する。
final class ImagePhotoProcessor implements PhotoProcessor {
  ImagePhotoProcessor({
    this.maxPixels = 24000000,
    this.maxInputBytes = 128 * 1024 * 1024,
  }) {
    if (maxPixels <= 0 || maxInputBytes <= 0) {
      throw ArgumentError('Image limits must be positive');
    }
  }

  final int maxPixels;
  final int maxInputBytes;

  @override
  Future<SourcePhoto> normalize(Uint8List imageBytes) async {
    final bytes = _snapshot(imageBytes);
    final result = await _normalize(bytes, maxPixels);
    return SourcePhoto(
      bytes: result.bytes.asUnmodifiableView(),
      width: result.width,
      height: result.height,
    );
  }

  @override
  Future<RedactedJpeg> redact(
    SourcePhoto photo,
    List<HideRegion> regions,
  ) async {
    final bytes = _snapshot(photo.bytes);
    final rectangles = [
      for (final r in regions)
        (left: r.left, top: r.top, right: r.right, bottom: r.bottom),
    ];
    final result = await _redact(
      bytes,
      photo.width,
      photo.height,
      rectangles,
      maxPixels,
    );
    return RedactedJpeg(
      bytes: result.bytes.asUnmodifiableView(),
      width: result.width,
      height: result.height,
    );
  }

  Uint8List _snapshot(Uint8List bytes) {
    if (bytes.length > maxInputBytes) {
      throw const PhotoProcessingException(
        PhotoProcessingFailure.imageTooLarge,
      );
    }
    return Uint8List.fromList(bytes);
  }
}

// 小さい送信可能な引数だけを捕捉し、processor や UI の状態を送らない。
Future<ProcessedPixels> _normalize(Uint8List bytes, int maxPixels) =>
    _run(() => normalizePixels(bytes, maxPixels));

Future<ProcessedPixels> _redact(
  Uint8List bytes,
  int width,
  int height,
  List<PixelRegion> regions,
  int maxPixels,
) => _run(() => redactPixels(bytes, width, height, regions, maxPixels));

Future<ProcessedPixels> _run(ProcessedPixels Function() work) async {
  try {
    return await Isolate.run(work, debugName: 'photo-processing');
  } on PhotoProcessingException {
    rethrow;
  } catch (_) {
    throw const PhotoProcessingException(PhotoProcessingFailure.workerFailed);
  }
}
