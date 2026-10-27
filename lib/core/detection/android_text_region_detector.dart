import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import '../photo/hide_region.dart';
import '../photo/photo_images.dart';
import 'region_detector.dart';

/// Bundled PP-OCRv5 mobile detector. Only bounding boxes cross the native bridge.
class AndroidTextRegionDetector implements RegionDetector {
  AndroidTextRegionDetector({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('dev.camereon/text_regions');
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
      // Bound the native decode/transfer size; work from the exact same oriented
      // pixels as the editor, not the camera JPEG's metadata.
      final png = await _thumbnail(photo);
      final result = await _channel.invokeMapMethod<String, dynamic>('detect', {
        'bytes': png,
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
          width > 960 ||
          height > 960 ||
          (result['boxes'] as List).length > 200) {
        throw const RegionDetectionException();
      }
      final regions = <HideRegion>{};
      for (final box in result['boxes'] as List) {
        if (box is! List || box.length != 4 || box.any((v) => v is! num)) {
          throw const RegionDetectionException();
        }
        final coordinates = box.cast<num>().map((v) => v.toDouble()).toList();
        if (coordinates.any((v) => !v.isFinite) ||
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
      );
    } catch (_) {
      throw const RegionDetectionException();
    } finally {
      _working = false;
    }
  }

  Future<Uint8List> _thumbnail(SourcePhoto photo) async {
    final factor =
        960 / (photo.width > photo.height ? photo.width : photo.height);
    final scale = factor < 1 ? factor : 1.0;
    final codec = await ui.instantiateImageCodec(
      photo.bytes,
      targetWidth: (photo.width * scale).round().clamp(1, 960),
      targetHeight: (photo.height * scale).round().clamp(1, 960),
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
