/// UI が入力の選び直し・再試行を案内するための失敗理由。
enum PhotoProcessingFailure {
  invalidImage,
  unsupportedFormat,
  imageTooLarge,
  invalidSource,
  invalidRegion,
  encodingFailed,
  workerFailed,
}

/// 画像やメタデータをメッセージに含めない。
final class PhotoProcessingException implements Exception {
  const PhotoProcessingException(this.reason);

  final PhotoProcessingFailure reason;

  @override
  String toString() => 'PhotoProcessingException(${reason.name})';
}
