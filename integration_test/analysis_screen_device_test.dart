import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camereon/core/analysis/analysis_services.dart';
import 'package:camereon/core/analysis/infrastructure/gemma_model_store.dart';
import 'package:camereon/core/analysis/infrastructure/gemma_scene_analyzer.dart';
import 'package:camereon/core/analysis/scene_analysis.dart';
import 'package:camereon/features/analysis/photo_analysis_entry.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'editor_support.dart';

class RecordingAnalyzer implements SceneAnalyzer {
  RecordingAnalyzer(this.delegate);
  final SceneAnalyzer delegate;
  SceneDescription? result;
  @override
  bool get isSupported => delegate.isSupported;
  @override
  bool get isBusy => delegate.isBusy;
  @override
  Future<void> cancel() => delegate.cancel();
  @override
  Future<SceneDescription> describe(
    AnalysisImage image, {
    AnalysisBackend backend = AnalysisBackend.automatic,
    List<OcrContextBlock> ocrBlocks = const [],
    required void Function(AnalysisPhase) onPhase,
    required void Function(String) onText,
  }) async => result = await delegate.describe(
    image,
    backend: backend,
    ocrBlocks: ocrBlocks,
    onPhase: onPhase,
    onText: onText,
  );
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('RUN_AI_DEVICE_TESTS');
  testWidgets(
    'edit, actual AI screen without HTTP, return, save and clean up',
    (tester) async {
      final store = GemmaModelStore();
      // flutter test removes its APK after completion. Provision this test's
      // debug app over USB after installation, before beginning inference.
      final wait = Stopwatch()..start();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('検証用モデルを USB で準備しています…'))),
        ),
      );
      while (!await store.isReady()) {
        if (wait.elapsed > const Duration(minutes: 3)) {
          throw StateError(
            'Provision the pinned model with prepare_app_model.py',
          );
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        await tester.pump();
      }
      final analyzer = RecordingAnalyzer(GemmaSceneAnalyzer(store));
      final data = await rootBundle.load(
        'tools/vlm-eval/fixtures/parcel_ja.png',
      );
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/CAP-analysis-integration.jpg');
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      await HttpOverrides.runZoned(
        () async {
          await tester.pumpWidget(
            MaterialApp(
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => PhotoAnalysisEntry(
                          loadImage: file.readAsBytes,
                          services: AnalysisServices(
                            models: store,
                            analyzer: analyzer,
                          ),
                          child: CapturedPhotoScreen(photo: XFile(file.path)),
                        ),
                      ),
                    ),
                    child: const Text('検証用の写真を開く'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('検証用の写真を開く'));
          await tester.pumpAndSettle();
          final candidate = tester
              .widget<CandidateOverlay>(find.byType(CandidateOverlay))
              .candidates
              .first;
          await tapCandidate(tester, candidate);
          SelectionPainter painter() =>
              tester
                      .widget<CustomPaint>(
                        find.byWidgetPredicate(
                          (w) =>
                              w is CustomPaint && w.painter is SelectionPainter,
                        ),
                      )
                      .painter!
                  as SelectionPainter;
          final selected = painter().regions.single;
          await tester.tap(find.text('端末内で写真を解析'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('写真を解析する'));
          await tester.tap(find.text('写真を解析する'));
          await tester.pumpAndSettle(
            const Duration(milliseconds: 100),
            EnginePhase.sendSemanticsUpdate,
            const Duration(minutes: 3),
          );
          expect(analyzer.result, isNotNull);
          expect(find.text('AI の説明（参考）'), findsOneWidget);
          expect(find.text(analyzer.result!.text), findsOneWidget);
          // Synthetic fixture only. Production does not log scene descriptions.
          // ignore: avoid_print
          print(
            'AI_SCREEN_RESULT ${jsonEncode({'text': analyzer.result!.text, 'backend': analyzer.result!.backend, 'visionBackend': analyzer.result!.visionBackend, 'totalMs': analyzer.result!.totalTime.inMilliseconds, 'dartHttpBlocked': true})}',
          );
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(painter().regions, [selected]);
          await editorAction(tester, '保存前に確認');
          await tester.tap(find.text('写真に保存'));
          await tester.pumpAndSettle();
          expect(find.text('写真を保存しました'), findsOneWidget);
          await tester.tap(find.text('もう一枚'));
          await tester.pumpAndSettle();
          expect(find.text('検証用の写真を開く'), findsOneWidget);
          expect(await file.exists(), isFalse);
        },
        createHttpClient: (_) =>
            throw StateError('Inference must not use HTTP'),
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
