import '../photo/hide_region.dart';
import '../photo/photo_images.dart';

/// Shared candidate contract. Detectors only return regions, never OCR text.
enum CandidateKind {
  text('文字'),
  face('顔'),
  person('人物'),
  screen('画面');

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
  }) : candidates = List.unmodifiable(candidates);
  final List<RegionCandidate> candidates;
  final bool truncated;
}

abstract interface class RegionDetector {
  /// Coordinates are always in the normalized SourcePhoto, never screen pixels.
  Future<RegionDetection> detect(SourcePhoto photo);
}

class RegionDetectionException implements Exception {
  const RegionDetectionException();
}
