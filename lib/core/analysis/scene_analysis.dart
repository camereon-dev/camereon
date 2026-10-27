import 'dart:typed_data';

/// VLM 用にデコード・縮小した画像。編集・保存の SourcePhoto とは分ける。
class AnalysisImage {
  const AnalysisImage({
    required this.bytes,
    required this.width,
    required this.height,
  });
  final Uint8List bytes;
  final int width;
  final int height;
}

/// OCR 側から受け取る文字。位置の提案・リスク評価は後続で扱う。
class OcrContextBlock {
  const OcrContextBlock({required this.id, required this.text});
  final String id;
  final String text;
}

enum AnalysisBackend { automatic, compatible }

enum AnalysisPhase { loadingModel, describing, releasing }

class SceneDescription {
  const SceneDescription({
    required this.text,
    required this.loadTime,
    required this.totalTime,
    required this.firstOutputTime,
    required this.backend,
    required this.visionBackend,
  });
  final String text;
  final Duration loadTime;
  final Duration totalTime;
  final Duration? firstOutputTime;
  final String backend;
  final String visionBackend;
}

enum AnalysisFailureKind {
  unsupported,
  busy,
  missingModel,
  storage,
  network,
  integrity,
  inference,
}

enum AnalysisFailureStage {
  initializing,
  registeringModel,
  loadingModel,
  creatingSession,
  preparingInput,
  generating,
  releasing,
}

class AnalysisFailure implements Exception {
  const AnalysisFailure(this.kind, {this.stage});
  final AnalysisFailureKind kind;
  // Only a fixed stage is exposed; SDK messages can contain paths or inputs.
  final AnalysisFailureStage? stage;
}

class AnalysisCancelled implements Exception {
  const AnalysisCancelled();
}

abstract interface class AnalysisModelStore {
  int get downloadSize;
  Future<int> downloadedBytes();
  Future<bool> isReady();
  Future<void> download({
    required void Function(int received, int total) onProgress,
  });
  void cancelDownload();
  Future<void> delete();
}

abstract interface class SceneAnalyzer {
  bool get isSupported;
  bool get isBusy;
  Future<SceneDescription> describe(
    AnalysisImage image, {
    AnalysisBackend backend = AnalysisBackend.automatic,
    List<OcrContextBlock> ocrBlocks = const [],
    required void Function(AnalysisPhase phase) onPhase,
    required void Function(String text) onText,
  });
  Future<void> cancel();
}
