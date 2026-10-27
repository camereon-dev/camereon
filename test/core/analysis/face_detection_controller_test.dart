import 'dart:async';
import 'dart:typed_data';

import 'package:camereon/core/analysis/face_detection.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/features/analysis/face_detection_controller.dart';
import 'package:flutter_test/flutter_test.dart';

class PendingDetector implements PhotoFaceDetector {
  Completer<List<FaceCandidate>> pending = Completer();
  int calls = 0;
  @override
  Future<List<FaceCandidate>> detect(SourcePhoto source) {
    calls++;
    return pending.future;
  }
}

void main() {
  final source = SourcePhoto(bytes: Uint8List(0), width: 1, height: 1);
  test(
    'cancel discards late result and waits for native completion before retry',
    () async {
      final detector = PendingDetector();
      final controller = FaceDetectionController(detector);
      final run = controller.detect(source);
      controller.cancel();
      await controller.detect(source);
      expect(detector.calls, 1);
      expect(controller.canRetry, isFalse);
      detector.pending.complete([]);
      await run;
      expect(controller.status, FaceDetectionStatus.cancelled);
      expect(controller.canRetry, isTrue);
      detector.pending = Completer();
      final retry = controller.detect(source);
      detector.pending.complete([]);
      await retry;
      expect(controller.status, FaceDetectionStatus.ready);
      controller.dispose();
    },
  );
  test('dispose ignores errors from native and never notifies again', () async {
    final detector = PendingDetector();
    final controller = FaceDetectionController(detector);
    final run = controller.detect(source);
    controller.dispose();
    detector.pending.completeError(StateError('failure'));
    await run;
  });
}
