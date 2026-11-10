import 'dart:typed_data';
import 'dart:ui' as ui;

import '../photo/hide_region.dart';
import '../photo/photo_images.dart';

/// Shared candidate contract. Detectors only return regions, never OCR text.
enum CandidateKind {
  text('文字'),
  face('顔'),
  person('人物'),
  screen('画面'),

  /// Cars, motorcycles, buses and trucks: offered for their number plates.
  vehicle('車両');

  const CandidateKind(this.label);
  final String label;
}

class RegionCandidate {
  const RegionCandidate({required this.kind, required this.region});
  final CandidateKind kind;
  final HideRegion region;
}

class RegionDetection {
  RegionDetection({
    required List<RegionCandidate> candidates,
    this.truncated = false,
    this.partial = false,
  }) : candidates = List.unmodifiable(candidates);
  final List<RegionCandidate> candidates;
  final bool truncated;

  /// Some stages failed, but successful candidates remain available for editing.
  final bool partial;
}

abstract interface class RegionDetector {
  /// Coordinates are always in the normalized SourcePhoto, never screen pixels.
  Future<RegionDetection> detect(SourcePhoto photo);
}

class RegionDetectionException implements Exception {
  const RegionDetectionException();
}

class RawPixels {
  const RawPixels(this.bytes, this.width, this.height);
  final Uint8List bytes;
  final int width;
  final int height;
}

/// Decode the normalized photo once, bounded to [maxSide], as RGBA pixels.
/// Encoding a 2560px PNG took 0.8-0.95s on the emulator; raw bytes take ~60ms.
Future<RawPixels> rawThumbnail(SourcePhoto photo, int maxSide) async {
  final longest = photo.width > photo.height ? photo.width : photo.height;
  final scale = longest > maxSide ? maxSide / longest : 1.0;
  final codec = await ui.instantiateImageCodec(
    photo.bytes,
    targetWidth: (photo.width * scale).round().clamp(1, maxSide),
    targetHeight: (photo.height * scale).round().clamp(1, maxSide),
  );
  try {
    final frame = await codec.getNextFrame();
    try {
      final data = await frame.image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (data == null) throw const RegionDetectionException();
      return RawPixels(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        frame.image.width,
        frame.image.height,
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
