import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:camereon/core/photo/photo_processor.dart';
import 'package:camereon/core/photo/photo_saver.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class FakeProcessor implements PhotoProcessor {
  FakeProcessor(int width, int height) {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(220, 220, 220));
    source = SourcePhoto(
      bytes: img.encodePng(image),
      width: width,
      height: height,
    );
    jpeg = RedactedJpeg(
      bytes: img.encodeJpg(image),
      width: width,
      height: height,
    );
  }
  late SourcePhoto source;
  late RedactedJpeg jpeg;
  List<HideRegion>? received;
  bool fail = false;
  bool failLoad = false;
  Completer<RedactedJpeg>? pending;

  @override
  Future<SourcePhoto> normalize(Uint8List bytes) async {
    if (failLoad) throw StateError('load');
    return source;
  }

  @override
  Future<RedactedJpeg> redact(
    SourcePhoto photo,
    List<HideRegion> regions,
  ) async {
    expect(identical(photo, source), isTrue);
    received = List.of(regions);
    if (fail) throw StateError('processing');
    return pending == null ? jpeg : pending!.future;
  }
}

class FakeSaver implements PhotoSaver {
  SaveResult result = const SaveSucceeded();
  int calls = 0;
  RedactedJpeg? received;
  Completer<SaveResult>? pending;
  @override
  Future<SaveResult> save(RedactedJpeg jpeg) async {
    calls++;
    received = jpeg;
    return pending == null ? result : pending!.future;
  }
}

SelectionPainter painter(WidgetTester tester) =>
    tester
            .widget<CustomPaint>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is CustomPaint && widget.painter is SelectionPainter,
              ),
            )
            .painter!
        as SelectionPainter;

Future<void> open(
  WidgetTester tester,
  FakeProcessor processor,
  FakeSaver saver,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: CapturedPhotoScreen(
        photo: XFile.fromData(processor.source.bytes),
        processor: processor,
        saver: saver,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> select(
  WidgetTester tester, {
  Offset start = const Offset(.1, .1),
  Offset end = const Offset(.6, .6),
}) async {
  final rect = tester.getRect(find.bySemanticsLabel('撮影した写真'));
  final gesture = await tester.startGesture(
    rect.topLeft + Offset(rect.width * start.dx, rect.height * start.dy),
  );
  await gesture.moveTo(
    rect.topLeft + Offset(rect.width * end.dx, rect.height * end.dy),
  );
  await gesture.up();
  await tester.pump();
}

void main() {
  for (final dimensions in [(200, 100), (100, 200)]) {
    testWidgets('$dimensions: pixel coordinates, overlap, undo and reset', (
      tester,
    ) async {
      final processor = FakeProcessor(dimensions.$1, dimensions.$2);
      await open(tester, processor, FakeSaver());
      await select(tester);
      final first = painter(tester).regions.single;
      expect(first.left, closeTo(dimensions.$1 * .1, 1));
      expect(first.top, closeTo(dimensions.$2 * .1, 1));
      expect(first.right, closeTo(dimensions.$1 * .6, 1));
      expect(first.bottom, closeTo(dimensions.$2 * .6, 1));
      await select(
        tester,
        start: const Offset(.9, .9),
        end: const Offset(.4, .4),
      );
      expect(painter(tester).regions.length, 2);
      await tester.tap(find.text('取り消す'));
      await tester.pump();
      expect(painter(tester).regions, [first]);
      await tester.tap(find.text('保存前に確認'));
      await tester.pumpAndSettle();
      expect(processor.received, [first]);
      await tester.tap(find.text('編集へ戻る'));
      await tester.pumpAndSettle();
      expect(painter(tester).regions, [first]);
      await tester.tap(find.text('すべてリセット'));
      await tester.pump();
      expect(painter(tester).regions, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'letterbox starts ignored, image edge clamped, cancelled drag discarded',
    (tester) async {
      await open(tester, FakeProcessor(400, 100), FakeSaver());
      final canvas = tester.getRect(find.byKey(const ValueKey('photo-canvas')));
      final image = tester.getRect(find.bySemanticsLabel('撮影した写真'));
      final outside = await tester.startGesture(
        canvas.topLeft + const Offset(10, 10),
      );
      await outside.moveTo(image.center);
      await outside.up();
      await tester.pump();
      expect(painter(tester).regions, isEmpty);
      final gesture = await tester.startGesture(image.center);
      await gesture.moveTo(image.bottomRight + const Offset(20, 20));
      await gesture.up();
      await tester.pump();
      expect(painter(tester).regions.single.right, 400);
      expect(painter(tester).regions.single.bottom, 100);
      final cancel = await tester.startGesture(image.center);
      await cancel.moveBy(const Offset(-60, -30));
      await cancel.cancel();
      await tester.pump();
      expect(painter(tester).regions.length, 1);
    },
  );

  testWidgets(
    'processing and save failures preserve edits; only completed save succeeds',
    (tester) async {
      final processor = FakeProcessor(200, 100)..fail = true;
      final saver = FakeSaver()
        ..result = const SaveFailed(SaveFailureReason.permissionDenied);
      await open(tester, processor, saver);
      await select(tester);
      final selected = painter(tester).regions.single;
      await tester.tap(find.text('保存前に確認'));
      await tester.pumpAndSettle();
      expect(painter(tester).regions, [selected]);
      processor.fail = false;
      await tester.tap(find.text('保存前に確認'));
      await tester.pumpAndSettle();
      expect(
        find.text('隠し忘れがないか確認してください。安全を完全に保証するものではありません。'),
        findsOneWidget,
      );
      await tester.tap(find.text('写真に保存'));
      await tester.pumpAndSettle();
      expect(find.text('写真を保存しました'), findsNothing);
      expect(find.text('設定を開く'), findsOneWidget);
      await tester.tap(find.text('編集へ戻る'));
      await tester.pumpAndSettle();
      expect(painter(tester).regions, [selected]);
      await tester.tap(find.text('保存前に確認'));
      await tester.pumpAndSettle();
      saver.pending = Completer<SaveResult>();
      await tester.tap(find.text('写真に保存'));
      await tester.pump();
      await tester.tap(find.text('写真に保存'));
      await tester.pump();
      expect(saver.calls, 2);
      expect(find.text('写真を保存しました'), findsNothing);
      saver.pending!.complete(const SaveSucceeded());
      await tester.pumpAndSettle();
      expect(find.text('写真を保存しました'), findsOneWidget);
      expect(identical(saver.received, processor.jpeg), isTrue);
    },
  );

  testWidgets('save success can return to camera and delete temp file', (
    tester,
  ) async {
    final file = File(
      '${Directory.systemTemp.path}/camereon-captured-screen-${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    addTearDown(() async {
      if (await file.exists()) {
        await file.delete();
      }
    });
    await file.writeAsBytes([0x01, 0x02, 0x03]);
    final processor = FakeProcessor(200, 100);
    final saver = FakeSaver();

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => CapturedPhotoScreen(
                    photo: XFile(file.path),
                    processor: processor,
                    saver: saver,
                  ),
                ),
              ),
              child: const Text('編集を開く'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('編集を開く'));
    await tester.pumpAndSettle();
    await select(tester);
    await tester.tap(find.text('保存前に確認'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('写真に保存'));
    await tester.pumpAndSettle();
    expect(find.text('写真を保存しました'), findsOneWidget);

    await tester.tap(find.text('もう一枚'));
    await tester.pumpAndSettle();

    expect(find.text('編集を開く'), findsOneWidget);
    expect(await file.exists(), isFalse);
  });

  testWidgets('retake and system back ask before discarding edits', (
    tester,
  ) async {
    await open(tester, FakeProcessor(200, 100), FakeSaver());
    await select(tester);
    await tester.tap(find.text('撮り直す'));
    await tester.pumpAndSettle();
    expect(find.text('編集を破棄しますか？'), findsOneWidget);
    await tester.tap(find.text('編集を続ける'));
    await tester.pumpAndSettle();
    expect(painter(tester).regions.length, 1);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('編集を破棄しますか？'), findsOneWidget);
  });

  testWidgets('load failure permits retry', (tester) async {
    final processor = FakeProcessor(200, 100)..failLoad = true;
    await open(tester, processor, FakeSaver());
    expect(find.text('再試行'), findsOneWidget);
    processor.failLoad = false;
    await tester.tap(find.text('再試行'));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('撮影した写真'), findsOneWidget);
  });

  testWidgets('small screen and enlarged text stay usable', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester, FakeProcessor(100, 200), FakeSaver());
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('保存前に確認'));
    await tester.tap(find.text('保存前に確認'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
