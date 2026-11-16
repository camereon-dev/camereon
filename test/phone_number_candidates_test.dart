import 'dart:ui' as ui;

import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

void main() {
  final text = editor.candidate(
    CandidateKind.text,
    const Rect.fromLTRB(10, 10, 190, 35),
  );
  final phone = editor.candidate(
    CandidateKind.phone,
    const Rect.fromLTRB(90, 10, 190, 35),
  );
  final person = editor.candidate(
    CandidateKind.person,
    const Rect.fromLTRB(10, 45, 50, 95),
  );

  test(
    'phone mask is opaque before asynchronous frosted preview is ready',
    () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 200, 100),
        Paint()..color = Colors.black,
      );
      SelectionPainter(
        regions: [phone.region],
        opaqueRegions: {phone.region},
        imageWidth: 200,
        imageHeight: 100,
      ).paint(canvas, const Size(200, 100));
      final picture = recorder.endRecording();
      final image = await picture.toImage(200, 100);
      try {
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        ))!;
        expect(bytes.getUint8((20 * 200 + 140) * 4), 255);
        expect(bytes.getUint8((20 * 200 + 50) * 4), 0);
      } finally {
        image.dispose();
        picture.dispose();
      }
    },
  );

  testWidgets('only phone candidates are automatically applied and saved', (
    tester,
  ) async {
    final texts = editor.FakeDetector()..candidates.addAll([text, phone]);
    final objects = editor.FakeDetector()..candidates.add(person);
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    await editor.open(tester, processor, saver, texts: texts, objects: objects);
    expect(
      editor.overlay(tester).candidates,
      containsAll([text, phone, person]),
    );
    expect(editor.overlay(tester).selectedCandidates, {phone});
    expect(find.byKey(const ValueKey('kind-chip-phone')), findsOneWidget);
    expect(find.byKey(const ValueKey('kind-chip-text')), findsOneWidget);
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, [phone.region]);
    await editor.tapText(tester, '写真に保存');
    expect(saver.calls, 1);
  });

  testWidgets('revealed phones stay revealed after a partial-scan retry', (
    tester,
  ) async {
    final texts = editor.FakeDetector()
      ..partial = true
      ..candidates.addAll([text, phone]);
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      texts: texts,
    );
    await editor.tapPixel(tester, const Offset(140, 20));
    expect(editor.overlay(tester).selectedCandidates, isEmpty);
    texts.partial = false;
    // A second pass may shift the box slightly without overriding the user's choice.
    texts.candidates[1] = editor.candidate(
      CandidateKind.phone,
      const Rect.fromLTRB(91, 10, 190, 35),
    );
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(texts.calls, 2);
    expect(editor.overlay(tester).selectedCandidates, isEmpty);
    expect(editor.overlay(tester).candidates, contains(text));
  });

  testWidgets(
    'undo restores automatic phones after another candidate is selected',
    (tester) async {
      final texts = editor.FakeDetector()..candidates.addAll([text, phone]);
      final objects = editor.FakeDetector()..candidates.add(person);
      await editor.open(
        tester,
        editor.FakeProcessor(200, 100),
        editor.FakeSaver(),
        texts: texts,
        objects: objects,
      );
      await editor.tapPixel(tester, const Offset(30, 65));
      expect(editor.overlay(tester).selectedCandidates, {phone, person});
      await editor.tapText(tester, '取り消す');
      expect(editor.overlay(tester).selectedCandidates, {phone});
      await editor.tapText(tester, '取り消す');
      expect(editor.overlay(tester).selectedCandidates, isEmpty);
      await tester.tap(find.byKey(const ValueKey('kind-chip-phone')));
      await tester.pumpAndSettle();
      expect(editor.overlay(tester).selectedCandidates, {phone});
    },
  );

  testWidgets(
    'phone OCR failure leaves ordinary text selectable and saveable',
    (tester) async {
      final texts = editor.FakeDetector()
        ..partial = true
        ..candidates.add(text);
      final processor = editor.FakeProcessor(200, 100);
      await editor.open(tester, processor, editor.FakeSaver(), texts: texts);
      expect(editor.overlay(tester).selectedCandidates, isEmpty);
      expect(editor.overlay(tester).candidates, contains(text));
      await editor.tapPixel(tester, const Offset(50, 20));
      await editor.tapText(tester, '保存前に確認');
      expect(processor.received, [text.region]);
    },
  );
}
