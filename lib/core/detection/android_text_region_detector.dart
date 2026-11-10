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
          result['boxes'] is! List ||
          (result['polygons'] != null &&
              (result['polygons'] is! List ||
                  (result['polygons'] as List).length !=
                      (result['boxes'] as List).length))) {
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
      final polygons = result['polygons'] as List?;
      final boxes = result['boxes'] as List;
      for (var index = 0; index < boxes.length; index++) {
        final box = boxes[index];
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
        final rect = ui.Rect.fromLTRB(
          coordinates[0] * photo.width / width,
          coordinates[1] * photo.height / height,
          coordinates[2] * photo.width / width,
          coordinates[3] * photo.height / height,
        );
        // The outline follows the text's slant; the box stays its bounds.
        final region =
            _polygon(polygons?[index], width, height, photo) ??
            HideRegion.fromRect(
              rect,
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

  HideRegion? _polygon(
    Object? flat,
    double width,
    double height,
    SourcePhoto photo,
  ) {
    if (flat == null) return null;
    if (flat is! List || flat.length < 6 || flat.length.isOdd) {
      throw const RegionDetectionException();
    }
    final values = <double>[];
    for (final v in flat) {
      if (v is! num || !v.isFinite || v < 0) {
        throw const RegionDetectionException();
      }
      values.add(v.toDouble());
    }
    final points = <ui.Offset>[];
    for (var i = 0; i < values.length; i += 2) {
      if (values[i] > width || values[i + 1] > height) {
        throw const RegionDetectionException();
      }
      points.add(
        ui.Offset(
          values[i] * photo.width / width,
          values[i + 1] * photo.height / height,
        ),
      );
    }
    return HideRegion.polygon(
      points,
      imageWidth: photo.width,
      imageHeight: photo.height,
    );
  }
}
