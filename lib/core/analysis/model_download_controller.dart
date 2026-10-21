import 'package:flutter/foundation.dart';

import 'scene_analysis.dart';

/// App lifetime transfer state. Routes only subscribe; leaving a route neither
/// cancels the transfer nor loses its progress. Disk checkpoints survive restart.
class ModelDownloadController extends ChangeNotifier {
  ModelDownloadController(this.models) : total = models.downloadSize;

  final AnalysisModelStore models;
  final int total;
  bool active = false;
  bool pausing = false;
  bool completed = false;
  int received = 0;
  Object? error;
  double? bytesPerSecond;
  Future<void>? _task;

  Duration? get remaining {
    final speed = bytesPerSecond;
    if (!active || speed == null || speed <= 0 || received >= total) {
      return null;
    }
    return Duration(seconds: ((total - received) / speed).ceil());
  }

  Future<void> restore() async {
    if (active) return;
    final saved = await models.downloadedBytes();
    if (active) return;
    received = saved;
    notifyListeners();
  }

  Future<void> start() {
    if (_task != null) return _task!;
    active = true;
    pausing = false;
    completed = false;
    error = null;
    bytesPerSecond = null;
    notifyListeners();
    return _task = _run();
  }

  Future<void> _run() async {
    final watch = Stopwatch()..start();
    int? startingBytes;
    try {
      await models.download(
        onProgress: (current, _) {
          // Reset the rate if the server has to restart a full response.
          if (current < (startingBytes ?? current)) {
            startingBytes = current;
            watch.reset();
            bytesPerSecond = null;
          }
          startingBytes ??= current;
          received = current;
          final seconds = watch.elapsedMilliseconds / 1000;
          if (seconds >= 1 && current > startingBytes!) {
            bytesPerSecond = (current - startingBytes!) / seconds;
          }
          notifyListeners();
        },
      );
      received = total;
      completed = true;
    } catch (failure) {
      error = failure;
      // The file is closed before download() returns or throws.
      try {
        received = await models.downloadedBytes();
      } catch (_) {
        // Preserve the last known progress if storage cannot be inspected.
      }
    } finally {
      active = false;
      pausing = false;
      _task = null;
      notifyListeners();
    }
  }

  void pause() {
    if (!active || pausing) return;
    pausing = true;
    models.cancelDownload();
    notifyListeners();
  }

  void reset() {
    received = 0;
    completed = false;
    error = null;
    bytesPerSecond = null;
    notifyListeners();
  }
}
