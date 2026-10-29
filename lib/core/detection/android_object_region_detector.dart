import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../photo/hide_region.dart';
import '../photo/photo_images.dart';
import 'region_detector.dart';

/// Bundled YOLO26s. Person, display, laptop and phone regions only.
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
      final png = await _thumbnail(photo);
      final result = await _channel.invokeMapMethod<String, dynamic>('detect', {
        'bytes': png,
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
        final region = HideRegion.fromRect(
          ui.Rect.fromLTRB(
            xy[0] * photo.width / width,
            xy[1] * photo.height / height,
            xy[2] * photo.width / width,
            xy[3] * photo.height / height,
          ),
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

  Future<Uint8List> _thumbnail(SourcePhoto photo) async {
    final longest = photo.width > photo.height ? photo.width : photo.height;
    final scale = longest > 1600 ? 1600 / longest : 1.0;
    final codec = await ui.instantiateImageCodec(
      photo.bytes,
      targetWidth: (photo.width * scale).round().clamp(1, 1600),
      targetHeight: (photo.height * scale).round().clamp(1, 1600),
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data == null) throw const RegionDetectionException();
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }
}
