import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

/// Measurement only: compares runtime settings of the bundled detectors on
/// staged photos. Not an accuracy acceptance test; only candidate coordinates
/// and timings leave the device.
Future<(Uint8List, int, int, int)> thumbnail(
  SourcePhoto photo,
  int maxSide,
  ui.ImageByteFormat format,
) async {
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
      final watch = Stopwatch()..start();
      final data = (await frame.image.toByteData(format: format))!;
      return (
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        frame.image.width,
        frame.image.height,
        watch.elapsedMilliseconds,
      );
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'detector probe: timing and settings on staged photos',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/blackboard-eval');
      final manifest = File('${dir.path}/sources.json');
      await tester.runAsync(() async {
        final end = DateTime.now().add(const Duration(minutes: 3));
        while (!await manifest.exists()) {
          if (DateTime.now().isAfter(end)) throw StateError('Stage fixtures');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      });
      final sources = (jsonDecode(await manifest.readAsString()) as List)
          .cast<Map<String, dynamic>>();
      const timing = {
        'library-iida',
        'restaurant-chiyoda',
        'menu-today',
        'badge-wikicamp',
        'louvre-crowd',
        'museum-labels',
      };
      const faces = {'louvre-crowd', 'badge-wikicamp', 'restaurant-chiyoda'};
      const objects = {
        'parking-lpr',
        'parking-shizuoka',
        'louvre-crowd',
        'badge-wikicamp',
        'library-digital-signage',
        'car-civic',
      };
      const variants = <String, Map<String, Object>>{
        'cpu2': {'threads': 2},
        'cpu4': {'threads': 4},
        'xnn4': {'threads': 4, 'xnnpack': true},
      };
      const text = MethodChannel('dev.camereon/text_regions');
      const face = MethodChannel('dev.camereon/face_detection');
      const object = MethodChannel('dev.camereon/object_regions');
      final processor = FlutterPhotoProcessor();
      final report = <Map<String, Object>>[];
      final output = File('${dir.path}/probe.json');
      for (final item in sources) {
        final id = item['id'] as String;
        if (!timing.contains(id) &&
            !faces.contains(id) &&
            !objects.contains(id)) {
          continue;
        }
        final source = await processor.normalize(
          await File('${dir.path}/$id.jpg').readAsBytes(),
        );
        final record = <String, Object>{
          'id': id,
          'width': source.width,
          'height': source.height,
        };
        if (timing.contains(id)) {
          final (png, w, h, pngMs) = await thumbnail(
            source,
            2560,
            ui.ImageByteFormat.png,
          );
          final (raw, _, _, rawMs) = await thumbnail(
            source,
            2560,
            ui.ImageByteFormat.rawRgba,
          );
          record['encode'] = {
            'png_ms': pngMs,
            'png_bytes': png.length,
            'raw_ms': rawMs,
            'raw_bytes': raw.length,
          };
          record['transfer'] = [w, h];
          final runs = <String, Object>{};
          for (final entry in variants.entries) {
            // One cached session at a time keeps the probe's memory bounded.
            await text.invokeMethod<void>('release');
            final watch = Stopwatch()..start();
            final result = await text.invokeMapMethod<String, dynamic>(
              'detect',
              {
                'bytes': raw,
                'width': w,
                'height': h,
                'detailed': true,
                'tuning': entry.value,
              },
            );
            runs[entry.key] = {
              'wall_ms': watch.elapsedMilliseconds,
              'native_ms': result!['elapsedMs'],
              'passes': result['passes'],
              'count': (result['boxes'] as List).length,
              'boxes': result['boxes'],
            };
          }
          record['text'] = runs;
        }
        if (faces.contains(id)) {
          final runs = <String, Object>{};
          for (final size in [.05, .02]) {
            final watch = Stopwatch()..start();
            final result = await face.invokeMapMethod<String, dynamic>(
              'detect',
              {
                'bytes': source.bytes,
                'width': source.width,
                'height': source.height,
                'minFaceSize': size,
              },
            );
            runs['$size'] = {
              'wall_ms': watch.elapsedMilliseconds,
              'input': [result!['width'], result['height']],
              'faces': result['faces'],
            };
          }
          record['faces'] = runs;
        }
        if (objects.contains(id)) {
          final (png, w, h, _) = await thumbnail(
            source,
            1600,
            ui.ImageByteFormat.png,
          );
          final runs = <String, Object>{};
          for (final variant in ['cpu2', 'xnn4']) {
            await text.invokeMethod<void>('release');
            final watch = Stopwatch()..start();
            final result = await object.invokeMapMethod<String, dynamic>(
              'detect',
              {'bytes': png, 'tuning': variants[variant]},
            );
            runs[variant] = {
              'wall_ms': watch.elapsedMilliseconds,
              'native_ms': result!['elapsedMs'],
              'input': [w, h],
              'candidates': result['candidates'],
            };
          }
          record['objects'] = runs;
        }
        report.add(record);
        await output.writeAsString(jsonEncode(report));
        // ignore: avoid_print
        print('PROBE_CASE $id');
      }
      // ignore: avoid_print
      print('PROBE_READY');
      await tester.runAsync(() async {
        final end = DateTime.now().add(const Duration(seconds: 90));
        while (!await File('${dir.path}/collected').exists()) {
          if (DateTime.now().isAfter(end)) throw StateError('Collect results');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      });
    },
    skip: !const bool.fromEnvironment('RUN_DETECTOR_PROBE'),
    timeout: Timeout.none,
  );
}
