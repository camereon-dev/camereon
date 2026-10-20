import 'dart:typed_data';

import 'hide_region.dart';
import 'photo_images.dart';

/// 写真の正規化と黒塗りの焼き込み。画面から切り離し、端末内だけで処理する。
abstract interface class PhotoProcessor {
  /// 撮影・読み込みした画像を、向きを正規化しメタデータを除いた [SourcePhoto] にする。
  ///
  /// ImagePhotoProcessor は JPEG・静止 PNG を受け取り、中間 PNG を返す。
  /// 呼び出し時点の入力をコピーし、失敗は PhotoProcessingException で通知する。
  Future<SourcePhoto> normalize(Uint8List imageBytes);

  /// [regions] を不透明な黒で焼き込んだ JPEG を、[photo] と同じ画素サイズで作る。
  ///
  /// [photo] は normalize の結果を使う。空リストも許可する。
  /// 不正な寸法・領域は失敗とし、黙って領域を省かない。
  /// JPEG 再読込後の色には非可逆圧縮による誤差がある。
  Future<RedactedJpeg> redact(SourcePhoto photo, List<HideRegion> regions);
}
