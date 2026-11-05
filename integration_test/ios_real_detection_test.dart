import 'dart:io';

import 'package:camereon/core/analysis/infrastructure/mlkit_face_detector.dart';
import 'package:camereon/core/detection/android_object_region_detector.dart';
import 'package:camereon/core/detection/android_text_region_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/flutter_photo_processor.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iPhone: positive detections on public evaluation photographs', (
    tester,
  ) async {
    expect(Platform.isIOS, isTrue);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('公開評価写真で自動検出を検証中'))),
    );
    final directory = await getApplicationSupportDirectory();
    // Flutter's device test installation can replace the app data container.
    // Allow USB staging after this test app has launched; missing data still fails.
    debugPrint(
      'Waiting for USB evaluation fixtures in ${directory.path}/ios-evaluation',
    );
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (DateTime.now().isBefore(deadline)) {
      final ready = await Future.wait([
        for (final name in ['louvre-crowd', 'parking-lpr'])
          File('${directory.path}/ios-evaluation/$name.jpg').exists(),
      ]);
      if (ready.every((exists) => exists)) break;
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    for (final name in ['louvre-crowd', 'parking-lpr']) {
      final file = File('${directory.path}/ios-evaluation/$name.jpg');
      expect(
        await file.exists(),
        isTrue,
        reason: 'Stage documented evaluation fixtures over USB first.',
      );
      final photo = await FlutterPhotoProcessor().normalize(
        await file.readAsBytes(),
      );
      final watch = Stopwatch()..start();
      final faces = await MlKitFaceDetector().detect(photo);
      final objects = await AndroidObjectRegionDetector().detect(photo);
      final text = await AndroidTextRegionDetector().detect(photo);
      expect(
        objects.partial || objects.truncated || text.partial || text.truncated,
        isFalse,
      );
      expect(text.candidates, isNotEmpty);
      final kinds = objects.candidates.map((c) => c.kind).toSet();
      if (name == 'louvre-crowd') {
        expect(faces, isNotEmpty);
        expect(
          kinds,
          containsAll([CandidateKind.person, CandidateKind.screen]),
        );
      } else {
        expect(kinds, contains(CandidateKind.vehicle));
      }
      expect(
        objects.candidates.any((c) => c.region.shape == HideShape.polygon),
        isTrue,
      );
      for (final c in [...objects.candidates, ...text.candidates]) {
        expect(c.region.left, greaterThanOrEqualTo(0));
        expect(c.region.top, greaterThanOrEqualTo(0));
        expect(c.region.right, lessThanOrEqualTo(photo.width));
        expect(c.region.bottom, lessThanOrEqualTo(photo.height));
      }
      debugPrint(
        'iOS $name: faces=${faces.length}, objects=${{for (final kind in kinds) kind.name: objects.candidates.where((c) => c.kind == kind).length}}, text=${text.candidates.length}, ${watch.elapsedMilliseconds} ms',
      );
    }
  });
}
