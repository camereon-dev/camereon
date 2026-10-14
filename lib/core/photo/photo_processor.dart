import 'dart:typed_data';

import 'hide_region.dart';
import 'photo_images.dart';

/// 写真の正規化と黒塗りの焼き込み。画面から切り離し、端末内だけで処理する。
abstract interface class PhotoProcessor {
  /// 撮影・読み込みした画像を、向きを正規化しメタデータを除いた [SourcePhoto] にする。
  Future<SourcePhoto> normalize(Uint8List imageBytes);

  /// [regions] を不透明な黒で焼き込んだ JPEG を、[photo] と同じ画素サイズで作る。
  Future<RedactedJpeg> redact(SourcePhoto photo, List<HideRegion> regions);
}
