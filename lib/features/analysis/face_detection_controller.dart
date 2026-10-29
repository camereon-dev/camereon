import 'package:flutter/foundation.dart';

import '../../core/analysis/face_detection.dart';
import '../../core/photo/photo_images.dart';

enum FaceDetectionStatus { idle, detecting, ready, failed, cancelled }

class FaceDetectionController extends ChangeNotifier {
  FaceDetectionController(this.detector);
  final PhotoFaceDetector detector;
  FaceDetectionStatus status = FaceDetectionStatus.idle;
  List<FaceCandidate> candidates = const [];
  int _generation = 0;
  bool _disposed = false;
  bool _inFlight = false;
  bool get canRetry =>
      !_inFlight &&
      (status == FaceDetectionStatus.failed ||
          status == FaceDetectionStatus.cancelled);

  Future<void> detect(SourcePhoto source) async {
    if (_disposed || _inFlight) return;
    final generation = ++_generation;
    _inFlight = true;
    status = FaceDetectionStatus.detecting;
    notifyListeners();
    try {
      final result = await detector.detect(source);
      if (_disposed || generation != _generation) return;
      candidates = List.unmodifiable(result);
      status = FaceDetectionStatus.ready;
    } catch (_) {
      if (_disposed || generation != _generation) return;
      status = FaceDetectionStatus.failed;
    } finally {
      _inFlight = false;
      if (!_disposed) notifyListeners();
    }
  }

  void markDeferred() {
    if (_disposed || status != FaceDetectionStatus.idle) return;
    status = FaceDetectionStatus.cancelled;
    notifyListeners();
  }

  void cancel() {
    if (_disposed || status != FaceDetectionStatus.detecting) return;
    _generation++;
    status = FaceDetectionStatus.cancelled;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    super.dispose();
  }
}
