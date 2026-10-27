import 'package:flutter/services.dart';

import '../../photo/hide_region.dart';
import '../../photo/photo_images.dart';
import '../face_detection.dart';

class MlKitFaceDetector implements PhotoFaceDetector {
  static const channel = MethodChannel('dev.camereon/face_detection');

  @override
  Future<List<FaceCandidate>> detect(SourcePhoto source) async {
    final result = await channel.invokeMapMethod<String, dynamic>('detect', {
      'bytes': source.bytes,
      'width': source.width,
      'height': source.height,
    });
    if (result == null) throw const FormatException('Missing face result');
    final width = result['width'] as int;
    final height = result['height'] as int;
    if (width <= 0 || height <= 0) throw const FormatException('Invalid size');
    final candidates = <FaceCandidate>[];
    for (final raw in result['faces'] as List) {
      final values = (raw as List).cast<num>();
      if (values.length != 4) throw const FormatException('Invalid bounds');
      final region = restoreFaceRegion(
        Rect.fromLTRB(
          values[0].toDouble(),
          values[1].toDouble(),
          values[2].toDouble(),
          values[3].toDouble(),
        ),
        sourceWidth: source.width,
        sourceHeight: source.height,
        inputWidth: width,
        inputHeight: height,
      );
      if (region != null) {
        candidates.add(FaceCandidate('face-${candidates.length}', region));
      }
    }
    return List.unmodifiable(candidates);
  }
}

/// Provisional 10% margin on each side; tune against consented fixtures.
HideRegion? restoreFaceRegion(
  Rect bounds, {
  required int sourceWidth,
  required int sourceHeight,
  required int inputWidth,
  required int inputHeight,
  double margin = .1,
}) {
  if (inputWidth <= 0 ||
      inputHeight <= 0 ||
      bounds.width <= 0 ||
      bounds.height <= 0 ||
      !margin.isFinite ||
      margin < 0) {
    return null;
  }
  final x = sourceWidth / inputWidth;
  final y = sourceHeight / inputHeight;
  return HideRegion.fromRect(
    Rect.fromLTRB(
      (bounds.left - bounds.width * margin) * x,
      (bounds.top - bounds.height * margin) * y,
      (bounds.right + bounds.width * margin) * x,
      (bounds.bottom + bounds.height * margin) * y,
    ),
    imageWidth: sourceWidth,
    imageHeight: sourceHeight,
  );
}
