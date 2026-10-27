import '../photo/hide_region.dart';
import '../photo/photo_images.dart';

/// Shared candidate contract for text and a future face detector. No OCR text.
enum CandidateKind { text, face }

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
