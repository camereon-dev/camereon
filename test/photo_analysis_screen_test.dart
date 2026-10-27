import 'dart:async';
import 'dart:typed_data';

import 'package:camera/camera.dart';

import 'package:camereon/core/analysis/analysis_services.dart';
import 'package:camereon/core/analysis/scene_analysis.dart';
import 'package:camereon/features/analysis/photo_analysis_screen.dart';
import 'package:camereon/features/analysis/photo_analysis_entry.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/core/photo/photo_processor.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class Models implements AnalysisModelStore {
  @override
  int get downloadSize => 4;
  int saved = 0;
  @override
  Future<int> downloadedBytes() async => saved;
  bool ready = true;
  bool deleted = false;
  int cancellations = 0;
  int transfers = 0;
  Completer<void>? pending;
  @override
  Future<bool> isReady() async => ready;
  @override
  Future<void> download({required void Function(int, int) onProgress}) async {
    transfers++;
    saved = 2;
    onProgress(2, 4);
    await pending?.future;
    ready = true;
  }

  @override
  void cancelDownload() {
    cancellations++;
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(const AnalysisCancelled());
    }
  }

  @override
  Future<void> delete() async {
    ready = false;
    saved = 0;
    deleted = true;
  }
}

const description = SceneDescription(
  text: '架空の荷札が見えます。',
  loadTime: Duration(seconds: 1),
  totalTime: Duration(seconds: 2),
  firstOutputTime: Duration(milliseconds: 500),
  backend: 'cpu',
  visionBackend: 'cpu',
);

class Analyzer implements SceneAnalyzer {
  @override
  bool isSupported = true;
  @override
  bool isBusy = false;
  int cancellations = 0;
  int calls = 0;
  Completer<SceneDescription>? pending;
  AnalysisFailure? failure;
  bool failAutomatic = false;
  final backends = <AnalysisBackend>[];
  AnalysisImage? lastImage;
  @override
  Future<SceneDescription> describe(
    AnalysisImage image, {
    AnalysisBackend backend = AnalysisBackend.automatic,
    List<OcrContextBlock> ocrBlocks = const [],
    required void Function(AnalysisPhase) onPhase,
    required void Function(String) onText,
  }) async {
    calls++;
    backends.add(backend);
    lastImage = image;
    isBusy = true;
    try {
      if (failure != null) throw failure!;
      if (failAutomatic && backend == AnalysisBackend.automatic) {
        throw const AnalysisFailure(AnalysisFailureKind.inference);
      }
      onPhase(AnalysisPhase.describing);
      onText('解析中の説明');
      return pending == null ? description : await pending!.future;
    } finally {
      isBusy = false;
    }
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    if (pending != null && !pending!.isCompleted) {
      pending!.completeError(const AnalysisCancelled());
    }
  }
}

class Processor implements PhotoProcessor {
  Processor(this.source);
  final SourcePhoto source;
  bool failLoad = false;
  @override
  Future<SourcePhoto> normalize(Uint8List bytes) async {
    if (failLoad) throw StateError('decode failed');
    return source;
  }

  @override
  Future<RedactedJpeg> redact(SourcePhoto photo, List<HideRegion> regions) =>
      throw UnimplementedError();
}

/// Called inside runAsync: route transitions use pumped time, image decoding
/// uses engine IO. Require a visible, prepared image before returning.
Future<void> waitForPreparedAnalysis(WidgetTester tester) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (true) {
    await tester.pump(const Duration(milliseconds: 16));
    if (find.bySemanticsLabel('解析する写真').evaluate().isNotEmpty &&
        find.text('写真と解析用データを確認しています…').evaluate().isEmpty) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Image preparation did not finish');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<void> open(WidgetTester tester, Models models, Analyzer analyzer) async {
  final bytes = img.encodePng(img.Image(width: 40, height: 30));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoAnalysisScreen(
          loadImage: () async => bytes,
          services: AnalysisServices(models: models, analyzer: analyzer),
        ),
      ),
    );
    await waitForPreparedAnalysis(tester);
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('automatic inference failure retries once on CPU', (
    tester,
  ) async {
    final analyzer = Analyzer()..failAutomatic = true;
    await open(tester, Models(), analyzer);
    await tester.tap(find.text('写真を解析する'));
    await tester.pumpAndSettle();
    expect(analyzer.backends, [
      AnalysisBackend.automatic,
      AnalysisBackend.compatible,
    ]);
    expect(find.text(description.text), findsOneWidget);
    expect(find.text('互換モードで解析しました。'), findsOneWidget);
  });

  testWidgets('failure reports a fixed stage and backend without SDK details', (
    tester,
  ) async {
    final analyzer = Analyzer()
      ..failure = const AnalysisFailure(
        AnalysisFailureKind.inference,
        stage: AnalysisFailureStage.loadingModel,
      );
    await open(tester, Models(), analyzer);
    await tester.tap(find.text('写真を解析する'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('確認コード: loadingModel/compatible'),
      findsOneWidget,
    );
  });

  testWidgets('missing model failure does not retry inference', (tester) async {
    final analyzer = Analyzer()
      ..failure = const AnalysisFailure(AnalysisFailureKind.missingModel);
    await open(tester, Models(), analyzer);
    await tester.tap(find.text('写真を解析する'));
    await tester.pumpAndSettle();
    expect(analyzer.backends, [AnalysisBackend.automatic]);
  });

  testWidgets('failed CPU retry stops and a later attempt stays on CPU', (
    tester,
  ) async {
    final analyzer = Analyzer()
      ..failure = const AnalysisFailure(AnalysisFailureKind.inference);
    await open(tester, Models(), analyzer);
    await tester.tap(find.text('写真を解析する'));
    await tester.pumpAndSettle();
    expect(analyzer.backends, [
      AnalysisBackend.automatic,
      AnalysisBackend.compatible,
    ]);
    analyzer.failure = null;
    await tester.tap(find.text('写真を解析する'));
    await tester.pumpAndSettle();
    expect(analyzer.backends.last, AnalysisBackend.compatible);
    expect(analyzer.calls, 3);
  });

  testWidgets(
    'failed editor load blocks analysis; retry shares normalized pixels',
    (tester) async {
      final bytes = img.encodePng(img.Image(width: 200, height: 100));
      final processor = Processor(
        SourcePhoto(bytes: bytes, width: 200, height: 100),
      )..failLoad = true;
      final analyzer = Analyzer();
      await tester.pumpWidget(
        MaterialApp(
          home: PhotoAnalysisEntry(
            loadImage: () async =>
                throw StateError('must not read original again'),
            services: AnalysisServices(models: Models(), analyzer: analyzer),
            editorBuilder: (onSourceLoaded) => CapturedPhotoScreen(
              photo: XFile.fromData(Uint8List.fromList([1, 2, 3])),
              processor: processor,
              onSourceLoaded: onSourceLoaded,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, '端末内で写真を解析'),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.text('端末内で写真を解析'));
      await tester.pumpAndSettle();
      expect(find.byType(PhotoAnalysisScreen), findsNothing);
      processor.failLoad = false;
      await tester.ensureVisible(find.text('再試行'));
      await tester.tap(find.text('再試行'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('撮影した写真'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('端末内で写真を解析'));
        await waitForPreparedAnalysis(tester);
      });
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('解析する写真'), findsOneWidget);
      await tester.tap(find.text('写真を解析する'));
      await tester.pumpAndSettle();
      expect(
        (analyzer.lastImage!.width, analyzer.lastImage!.height),
        (200, 100),
      );
      expect(find.text(description.text), findsOneWidget);
    },
  );

  testWidgets(
    'shows streamed results, prevents duplicates and recovers from failure',
    (tester) async {
      final analyzer = Analyzer()..pending = Completer<SceneDescription>();
      await open(tester, Models(), analyzer);
      await tester.tap(find.text('写真を解析する'));
      await tester.pump();
      await tester.tap(find.text('写真を解析する'));
      await tester.pump();
      expect(analyzer.calls, 1);
      expect(find.text('解析中の説明'), findsOneWidget);
      analyzer.pending!.complete(description);
      await tester.pumpAndSettle();
      expect(find.text(description.text), findsOneWidget);
      analyzer.failure = const AnalysisFailure(AnalysisFailureKind.inference);
      await tester.tap(find.text('もう一度解析する'));
      await tester.pumpAndSettle();
      expect(find.text(description.text), findsNothing);
      expect(find.textContaining('解析を完了できませんでした'), findsOneWidget);
      analyzer.failure = null;
      analyzer.pending = null;
      await tester.tap(find.text('写真を解析する'));
      await tester.pumpAndSettle();
      expect(find.text(description.text), findsOneWidget);
    },
  );

  testWidgets('download cancellation permits retry and model deletion', (
    tester,
  ) async {
    final models = Models()
      ..ready = false
      ..pending = Completer<void>();
    await open(tester, models, Analyzer());
    await tester.tap(find.text('解析用データをダウンロード'));
    await tester.pump();
    await tester.ensureVisible(find.text('一時停止'));
    await tester.tap(find.text('一時停止'));
    await tester.pumpAndSettle();
    expect(models.cancellations, 1);
    expect(find.text('一時停止しました。取得済みデータを残しています。'), findsOneWidget);
    models.pending = null;
    await tester.tap(find.text('ダウンロードを再開'));
    await tester.pumpAndSettle();
    expect(find.text('写真を解析する'), findsOneWidget);
    await tester.ensureVisible(find.text('解析の設定'));
    await tester.tap(find.text('解析の設定'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('解析用データを削除'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('解析用データを削除'));
    await tester.pumpAndSettle();
    expect(models.deleted, isTrue);
    expect(find.text('解析用データをダウンロード'), findsOneWidget);
  });

  testWidgets(
    'download continues across navigation and reopening shares its progress',
    (tester) async {
      final models = Models()
        ..ready = false
        ..pending = Completer<void>();
      final services = AnalysisServices(models: models, analyzer: Analyzer());
      final bytes = img.encodePng(img.Image(width: 40, height: 30));
      await tester.pumpWidget(
        MaterialApp(
          home: PhotoAnalysisEntry(
            loadImage: () async => bytes,
            services: services,
            child: const Center(child: Text('編集画面')),
          ),
        ),
      );
      Future<void> enter() async {
        await tester.runAsync(() async {
          await tester.tap(find.text('端末内で写真を解析'));
          await waitForPreparedAnalysis(tester);
        });
        await tester.pump(const Duration(seconds: 1));
      }

      await enter();
      await tester.ensureVisible(find.text('解析用データをダウンロード'));
      await tester.tap(find.text('解析用データをダウンロード'));
      await tester.pump();
      expect(services.downloads.active, isTrue);
      await tester.runAsync(() async {
        await tester.pageBack();
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      });
      await tester.pumpAndSettle();
      expect(models.cancellations, 0);
      expect(services.downloads.active, isTrue);
      await enter();
      expect(find.text('一時停止'), findsOneWidget);
      expect(services.downloads.received, 2);
      expect(models.transfers, 1);
      models.pending!.complete();
      await tester.pumpAndSettle();
      expect(find.text('写真を解析する'), findsOneWidget);
      expect(models.cancellations, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'leaving a running analysis cancels it without stale UI updates',
    (tester) async {
      final analyzer = Analyzer()..pending = Completer<SceneDescription>();
      await open(tester, Models(), analyzer);
      await tester.tap(find.text('写真を解析する'));
      await tester.pump();
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
      expect(analyzer.cancellations, 1);
      expect(analyzer.isBusy, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsupported device never starts a model download', (
    tester,
  ) async {
    await open(tester, Models(), Analyzer()..isSupported = false);
    expect(find.text('写真の解析には Android 11 以上・ARM64 の端末が必要です。'), findsOneWidget);
    expect(find.text('解析用データをダウンロード'), findsNothing);
    expect(find.text('写真を解析する'), findsNothing);
  });

  testWidgets('opening and closing analysis preserves the editor selection', (
    tester,
  ) async {
    final bytes = img.encodePng(img.Image(width: 200, height: 100));
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoAnalysisEntry(
          loadImage: () async => bytes,
          services: AnalysisServices(models: Models(), analyzer: Analyzer()),
          child: CapturedPhotoScreen(
            photo: XFile.fromData(bytes),
            processor: Processor(
              SourcePhoto(bytes: bytes, width: 200, height: 100),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final imageRect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
    final gesture = await tester.startGesture(
      imageRect.center - const Offset(50, 30),
    );
    await gesture.moveTo(imageRect.center + const Offset(50, 30));
    await gesture.up();
    await tester.pump();
    SelectionPainter selection() =>
        tester
                .widget<CustomPaint>(
                  find.byWidgetPredicate(
                    (w) => w is CustomPaint && w.painter is SelectionPainter,
                  ),
                )
                .painter!
            as SelectionPainter;
    final regions = List<HideRegion>.of(selection().regions);
    expect(regions.length, 1);
    await tester.runAsync(() async {
      await tester.tap(find.text('端末内で写真を解析'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    expect(find.byType(PhotoAnalysisScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(selection().regions, regions);
  });
}
