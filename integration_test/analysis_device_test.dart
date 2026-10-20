import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:camereon/core/analysis/infrastructure/gemma_model_store.dart';
import 'package:camereon/core/analysis/infrastructure/gemma_scene_analyzer.dart';
import 'package:camereon/core/analysis/scene_analysis.dart';
import 'package:camereon/features/analysis/prepare_analysis_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const enabled = bool.fromEnvironment('RUN_AI_DEVICE_TESTS');
  testWidgets(
    'real Gemma: GPU/CPU, cancellation, retry and model deletion',
    (tester) async {
      final progress = ValueNotifier<String>('モデルを確認しています');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(title: const Text('AI 実機テスト')),
            body: Center(
              child: ValueListenableBuilder<String>(
                valueListenable: progress,
                builder: (_, text, _) =>
                    Text(text, textAlign: TextAlign.center),
              ),
            ),
          ),
        ),
      );
      void stage(String message) {
        progress.value = message;
        // Synthetic test metadata only, never a real photograph.
        // ignore: avoid_print
        print('AI_DEVICE_PHASE $message');
      }

      final store = GemmaModelStore();
      expect(
        await store.isReady(),
        isTrue,
        reason: 'Provision the pinned model before running this opt-in test',
      );
      final data = await rootBundle.load(
        'tools/vlm-eval/fixtures/parcel_ja.png',
      );
      final image = await prepareAnalysisImage(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      );
      final analyzer = GemmaSceneAnalyzer(store);
      expect(analyzer.isSupported, isTrue);
      final records = <Map<String, Object?>>[];
      for (final backend in AnalysisBackend.values) {
        stage('${backend.name}: 実行開始');
        await tester.pump();
        final result = await analyzer.describe(
          image,
          backend: backend,
          onPhase: (phase) => stage('${backend.name}: ${phase.name}'),
          onText: (_) {},
        );
        expect(result.text.trim(), isNotEmpty);
        expect(analyzer.isBusy, isFalse);
        final record = <String, Object?>{
          'requested': backend.name,
          'backend': result.backend,
          'visionBackend': result.visionBackend,
          'text': result.text,
          'loadMs': result.loadTime.inMilliseconds,
          'totalMs': result.totalTime.inMilliseconds,
          'firstOutputMs': result.firstOutputTime?.inMilliseconds,
          'maxRssBytes': ProcessInfo.maxRss,
        };
        records.add(record);
        // ignore: avoid_print
        print('AI_DEVICE_CASE ${jsonEncode(record)}');
      }
      stage('中止・重複実行を確認しています');
      await tester.pump();
      final pending = analyzer.describe(
        image,
        onPhase: (phase) {
          if (phase == AnalysisPhase.loadingModel) unawaited(analyzer.cancel());
        },
        onText: (_) {},
      );
      await expectLater(
        analyzer.describe(image, onPhase: (_) {}, onText: (_) {}),
        throwsA(
          isA<AnalysisFailure>().having(
            (e) => e.kind,
            'kind',
            AnalysisFailureKind.busy,
          ),
        ),
      );
      await expectLater(pending, throwsA(isA<AnalysisCancelled>()));
      expect(analyzer.isBusy, isFalse);
      stage('中止後の再実行を確認しています');
      await tester.pump();
      final retry = await analyzer.describe(
        image,
        backend: AnalysisBackend.compatible,
        onPhase: (_) {},
        onText: (_) {},
      );
      expect(retry.text, isNotEmpty);
      expect(analyzer.isBusy, isFalse);
      records.add({
        'case': 'retry-after-cancel',
        'backend': retry.backend,
        'totalMs': retry.totalTime.inMilliseconds,
      });
      // Only the synthetic fixture's response is included in test evidence.
      // ignore: avoid_print
      print('AI_DEVICE_RESULT ${jsonEncode(records)}');
      stage('モデル削除を確認しています');
      await store.delete();
      expect(await store.isReady(), isFalse);
      stage('AI 実機テスト完了');
      await tester.pump();
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
