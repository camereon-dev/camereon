import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../../core/analysis/scene_analysis.dart';

/// Decode exactly as the Flutter preview does, resize, and re-encode pixels.
/// This creates no saved photo and replaces no #10 editing/export processing.
Future<AnalysisImage> prepareAnalysisImage(Uint8List bytes) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  final codec = await ui.instantiateImageCodecWithSize(
    buffer,
    getTargetSize: (width, height) {
      final scale = math.min(1.0, 1024 / math.max(width, height));
      return ui.TargetImageSize(
        width: math.max(1, (width * scale).round()),
        height: math.max(1, (height * scale).round()),
      );
    },
  );
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) throw StateError('Could not prepare image');
      return AnalysisImage(
        bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        width: frame.image.width,
        height: frame.image.height,
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
