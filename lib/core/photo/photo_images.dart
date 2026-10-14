import 'package:flutter/foundation.dart';

/// 編集の元になる写真。
///
/// [PhotoProcessor.normalize] で作り、EXIF の向きを画素に反映済みで、
/// 位置情報などのメタデータを含まない。[width]・[height] はその画素サイズで、
/// [HideRegion] の座標系になる。
@immutable
class SourcePhoto {
  const SourcePhoto({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}

/// 黒塗りを焼き込んだ保存用の JPEG。元の [SourcePhoto] と同じ画素サイズ。
@immutable
class RedactedJpeg {
  const RedactedJpeg({
    required this.bytes,
    required this.width,
    required this.height,
  });

  final Uint8List bytes;
  final int width;
  final int height;
}
