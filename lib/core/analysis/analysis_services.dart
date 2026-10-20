import 'infrastructure/gemma_model_store.dart';
import 'infrastructure/gemma_scene_analyzer.dart';
import 'scene_analysis.dart';

/// Shared lifetime: at most one download and one model inference in the app.
class AnalysisServices {
  AnalysisServices({required this.models, required this.analyzer});
  final AnalysisModelStore models;
  final SceneAnalyzer analyzer;

  static final instance = _create();
  static AnalysisServices _create() {
    final store = GemmaModelStore();
    return AnalysisServices(models: store, analyzer: GemmaSceneAnalyzer(store));
  }
}
