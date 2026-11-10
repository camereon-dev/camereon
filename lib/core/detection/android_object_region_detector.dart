import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../photo/hide_region.dart';
import '../photo/mask_outline.dart';
import '../photo/photo_images.dart';
import 'region_detector.dart';

/// Bundled YOLO26s-seg. Person, display/laptop/phone and vehicle regions only.
/// Each candidate's silhouette mask is traced into a polygon; a candidate
/// without a usable mask falls back to its rectangle.
class AndroidObjectRegionDetector implements RegionDetector {
  AndroidObjectRegionDetector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.camereon/object_regions');

  final MethodChannel _channel;
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
      final pixels = await rawThumbnail(photo, 1600);
      final result = await _channel.invokeMapMethod<String, dynamic>('detect', {
        'bytes': pixels.bytes,
        'width': pixels.width,
        'height': pixels.height,
      });
      if (result == null ||
          result['width'] is! num ||
          result['height'] is! num ||
          result['candidates'] is! List ||
          result['truncated'] is! bool) {
        throw const RegionDetectionException();
      }
      final width = (result['width'] as num).toDouble();
      final height = (result['height'] as num).toDouble();
      if (!width.isFinite ||
          !height.isFinite ||
          width <= 0 ||
          height <= 0 ||
          width > 1600 ||
          height > 1600 ||
          (result['candidates'] as List).length > 200) {
        throw const RegionDetectionException();
      }
      final candidates = <RegionCandidate>[];
      for (final value in result['candidates'] as List) {
        if (value is! Map || value['box'] is! List) {
          throw const RegionDetectionException();
        }
        final kind = switch (value['kind']) {
          'person' => CandidateKind.person,
          'screen' => CandidateKind.screen,
          'vehicle' => CandidateKind.vehicle,
          _ => throw const RegionDetectionException(),
        };
        final box = value['box'] as List;
        if (box.length != 4 || box.any((v) => v is! num)) {
          throw const RegionDetectionException();
        }
        final xy = box.cast<num>().map((v) => v.toDouble()).toList();
        if (xy.any((v) => !v.isFinite) ||
            xy[0] < 0 ||
            xy[1] < 0 ||
            xy[2] > width ||
            xy[3] > height ||
            xy[0] >= xy[2] ||
            xy[1] >= xy[3]) {
          throw const RegionDetectionException();
        }
        final rect = ui.Rect.fromLTRB(
          xy[0] * photo.width / width,
          xy[1] * photo.height / height,
          xy[2] * photo.width / width,
          xy[3] * photo.height / height,
        );
        final region =
            _silhouette(value['mask'], width, height, photo) ??
            HideRegion.fromRect(
              rect,
              imageWidth: photo.width,
              imageHeight: photo.height,
            );
        if (region == null) throw const RegionDetectionException();
        if (!candidates.any((c) => c.kind == kind && c.region == region)) {
          candidates.add(RegionCandidate(kind: kind, region: region));
        }
      }
      return RegionDetection(
        candidates: candidates,
        truncated: result['truncated'] as bool,
      );
    } catch (_) {
      throw const RegionDetectionException();
    } finally {
      _working = false;
    }
  }

  /// Mask crops are 8-bit cells over a rectangle of the transferred image.
  HideRegion? _silhouette(
    Object? mask,
    double width,
    double height,
    SourcePhoto photo,
  ) {
    if (mask == null) return null;
    if (mask is! Map ||
        mask['width'] is! int ||
        mask['height'] is! int ||
        mask['bytes'] is! Uint8List) {
      throw const RegionDetectionException();
    }
    final w = mask['width'] as int;
    final h = mask['height'] as int;
    final bytes = mask['bytes'] as Uint8List;
    final edges = [
      for (final key in ['left', 'top', 'right', 'bottom']) mask[key],
    ];
    if (w <= 0 ||
        h <= 0 ||
        w * h > 1 << 20 ||
        bytes.length != w * h ||
        edges.any((v) => v is! num || !v.isFinite)) {
      throw const RegionDetectionException();
    }
    final e = edges.cast<num>().map((v) => v.toDouble()).toList();
    if (e[0] < 0 ||
        e[1] < 0 ||
        e[2] > width ||
        e[3] > height ||
        e[0] >= e[2] ||
        e[1] >= e[3]) {
      throw const RegionDetectionException();
    }
    // Too sparse a mask means the model is unsure of the outline.
    if (maskCoverage(bytes, w, h) < .05) return null;
    final outline = traceMask(bytes, w, h);
    if (outline == null) return null;
    final points = mapOutline(
      outline,
      w,
      h,
      ui.Rect.fromLTRB(
        e[0] * photo.width / width,
        e[1] * photo.height / height,
        e[2] * photo.width / width,
        e[3] * photo.height / height,
      ),
    );
    return HideRegion.polygon(
      points,
      imageWidth: photo.width,
      imageHeight: photo.height,
    );
  }
}
