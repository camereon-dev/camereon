import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../photo/hide_region.dart';
import '../photo/photo_images.dart';
import 'region_detector.dart';

/// Bundled PP-OCRv5 mobile detector. Only bounding boxes come back over the
/// bridge; the photo crosses it as raw RGBA pixels (no PNG round trip).
class AndroidTextRegionDetector implements RegionDetector {
  AndroidTextRegionDetector({MethodChannel? channel, this.detailed = true})
    : _channel = channel ?? const MethodChannel('dev.camereon/text_regions');
  final MethodChannel _channel;

  /// The legacy whole-image pass remains available for controlled comparisons.
  final bool detailed;
  int get _maxSide => detailed ? 2560 : 960;
  int get _maxCandidates => detailed ? 500 : 200;
  bool _working = false;

  @override
  Future<RegionDetection> detect(SourcePhoto photo) async {
    if (_working ||
        photo.width <= 0 ||
        photo.height <= 0 ||
        photo.bytes.isEmpty) {
      throw const RegionDetectionException();
    }
    _working = true;
    try {
      // Bound the transfer size; work from the exact same oriented pixels as
      // the editor, not the camera JPEG's metadata.
      final pixels = await rawThumbnail(photo, _maxSide);
      final result = await _channel.invokeMapMethod<String, dynamic>('detect', {
        'bytes': pixels.bytes,
        'width': pixels.width,
        'height': pixels.height,
        'detailed': detailed,
      });
      if (result == null ||
          result['width'] is! num ||
          result['height'] is! num ||
          result['boxes'] is! List) {
        throw const RegionDetectionException();
      }
      final width = (result['width'] as num).toDouble();
      final height = (result['height'] as num).toDouble();
      if (!width.isFinite ||
          !height.isFinite ||
          width <= 0 ||
          height <= 0 ||
          width > _maxSide ||
          height > _maxSide ||
          (result['boxes'] as List).length > _maxCandidates) {
        throw const RegionDetectionException();
      }
      final regions = <HideRegion>{};
      for (final box in result['boxes'] as List) {
        if (box is! List || box.length != 4 || box.any((v) => v is! num)) {
          throw const RegionDetectionException();
        }
        final coordinates = box.cast<num>().map((v) => v.toDouble()).toList();
        if (coordinates.any((v) => !v.isFinite) ||
            coordinates[0] < 0 ||
            coordinates[1] < 0 ||
            coordinates[2] > width ||
            coordinates[3] > height ||
            coordinates[0] >= coordinates[2] ||
            coordinates[1] >= coordinates[3]) {
          throw const RegionDetectionException();
        }
        final region = HideRegion.fromRect(
          ui.Rect.fromLTRB(
            coordinates[0] * photo.width / width,
            coordinates[1] * photo.height / height,
            coordinates[2] * photo.width / width,
            coordinates[3] * photo.height / height,
          ),
          imageWidth: photo.width,
          imageHeight: photo.height,
        );
        if (region == null) throw const RegionDetectionException();
        regions.add(region);
      }
      return RegionDetection(
        candidates: [
          for (final region in regions)
            RegionCandidate(kind: CandidateKind.text, region: region),
        ],
        truncated: result['truncated'] == true,
        partial: result['partial'] == true,
      );
    } catch (_) {
      throw const RegionDetectionException();
    } finally {
      _working = false;
    }
  }
}
