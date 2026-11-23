import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/hide_region.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

final selectionPainters = find.byWidgetPredicate(
  (w) => w is CustomPaint && w.painter is SelectionPainter,
);

void main() {
  final address = editor.candidate(
    CandidateKind.address,
    const Rect.fromLTRB(20, 20, 120, 60),
  );

  Future<editor.FakeProcessor> openWithAddress(
    WidgetTester tester, {
    RegionDetector? addresses,
    bool settle = true,
  }) async {
    final processor = editor.FakeProcessor(200, 100);
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      addresses: addresses ?? (editor.FakeDetector()..candidates.add(address)),
      includeOtherCandidates: false,
      settle: settle,
    );
    return processor;
  }

  testWidgets('the pen hides what it paints and is saved in order', (
    tester,
  ) async {
    final processor = await openWithAddress(tester);
    await editor.paint(tester, const [
      Offset(140, 70),
      Offset(160, 75),
      Offset(185, 80),
    ]);
    final regions = editor.painter(tester).regions;
    expect(regions, hasLength(2));
    expect(regions.first, address.region);
    final pen = regions.last;
    expect(pen.shape, HideShape.stroke);
    expect(pen.reveal, isFalse);
    expect(pen.contains(const Offset(160, 75)), isTrue);
    await editor.tapText(tester, '写真に保存');
    expect(processor.received, [address.region, pen]);
  });

  testWidgets('the eraser shows part of an automatic mask again', (
    tester,
  ) async {
    final processor = await openWithAddress(tester);
    await editor.tapText(tester, '消しゴムで戻す');
    await editor.paint(tester, const [Offset(30, 40), Offset(60, 40)]);
    final regions = editor.painter(tester).regions;
    expect(regions.first, address.region);
    expect(regions.last.reveal, isTrue);
    // The frame itself stays hidden; only the erased part is shown.
    expect(editor.overlay(tester).selectedCandidates, {address});
    await editor.tapText(tester, '写真に保存');
    expect(processor.received, regions);
  });

  testWidgets('erasing where nothing is hidden is not an edit', (tester) async {
    await openWithAddress(tester);
    await editor.tapText(tester, '消しゴムで戻す');
    await editor.paint(tester, const [Offset(150, 80), Offset(190, 90)]);
    expect(editor.painter(tester).regions, [address.region]);
    final undo = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.undo_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(undo.onPressed, isNull);
  });

  testWidgets('every stroke undoes and redoes as one step', (tester) async {
    await openWithAddress(tester);
    await editor.paint(tester, const [Offset(140, 70), Offset(180, 80)]);
    await editor.paint(tester, const [Offset(140, 90), Offset(180, 90)]);
    expect(editor.painter(tester).regions, hasLength(3));
    await editor.tapText(tester, '取り消す');
    expect(editor.painter(tester).regions, hasLength(2));
    await editor.tapText(tester, '取り消す');
    expect(editor.painter(tester).regions, [address.region]);
    await editor.tapText(tester, 'やり直す');
    await editor.tapText(tester, 'やり直す');
    expect(editor.painter(tester).regions, hasLength(3));
    // A new edit clears what could be redone.
    await editor.tapText(tester, '取り消す');
    await editor.tapPixel(tester, const Offset(50, 40));
    final redo = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.redo_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(redo.onPressed, isNull);
  });

  testWidgets('a second finger zooms instead of painting', (tester) async {
    await openWithAddress(tester);
    final before = tester.getRect(find.bySemanticsLabel('撮影した写真'));
    final center = before.center;
    final first = await tester.startGesture(
      center - const Offset(30, 0),
      pointer: 1,
    );
    await first.moveTo(center - const Offset(40, 0));
    await tester.pump();
    final second = await tester.startGesture(
      center + const Offset(30, 0),
      pointer: 2,
    );
    await first.moveTo(center - const Offset(90, 0));
    await second.moveTo(center + const Offset(90, 0));
    await tester.pump();
    await first.up();
    await second.up();
    await tester.pumpAndSettle();
    expect(editor.painter(tester).regions, [address.region]);
    final after = tester.getRect(find.bySemanticsLabel('撮影した写真'));
    expect(after.width, greaterThan(before.width * 1.4));
    // Zoomed in, a tap still toggles the frame under the finger.
    await tester.tapAt(
      after.topLeft + Offset(after.width * .35, after.height * .4),
    );
    await tester.pumpAndSettle();
    expect(editor.overlay(tester).selectedCandidates, isEmpty);
  });

  testWidgets('holding the eye shows the original until released', (
    tester,
  ) async {
    await openWithAddress(tester);
    expect(editor.painter(tester).regions, [address.region]);
    final peek = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('peek-original'))),
    );
    await tester.pump();
    expect(selectionPainters, findsNothing);
    await peek.up();
    await tester.pump();
    expect(editor.painter(tester).regions, [address.region]);
  });

  testWidgets('an address found after a stroke is not revealed by undo', (
    tester,
  ) async {
    // Addresses arrive late: retry after a partial first scan.
    final addresses = editor.FakeDetector()..partial = true;
    await openWithAddress(tester, addresses: addresses);
    await editor.paint(tester, const [Offset(140, 70), Offset(180, 80)]);
    addresses
      ..partial = false
      ..candidates.add(address);
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(editor.painter(tester).regions.first, address.region);
    await editor.tapText(tester, '取り消す');
    expect(editor.painter(tester).regions, [address.region]);
  });
}
