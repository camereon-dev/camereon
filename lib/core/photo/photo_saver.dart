import 'photo_images.dart';

/// 加工済みの画像を端末のギャラリーへ新しい画像として保存する。
abstract interface class PhotoSaver {
  Future<SaveResult> save(RedactedJpeg jpeg);
}

sealed class SaveResult {
  const SaveResult();
}

final class SaveSucceeded extends SaveResult {
  const SaveSucceeded();
}

final class SaveFailed extends SaveResult {
  const SaveFailed(this.reason);

  final SaveFailureReason reason;
}

enum SaveFailureReason {
  /// 保存に必要な権限が拒否された。再試行か設定の案内ができる。
  permissionDenied,

  /// 空き容量不足など、その他の理由で保存できなかった。
  failed,
}
