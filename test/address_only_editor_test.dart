import 'dart:async';
import 'dart:io';

import 'package:camereon/core/detection/place_name_dictionary.dart';

import 'package:camereon/core/detection/japanese_address_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

void main() {
  final dictionary = PlaceNameDictionary.fromBytes(
    File('assets/address_dictionary/names.bin').readAsBytesSync(),
  );
  testWidgets('bare dictionary names toggle and save independently', (
    tester,
  ) async {
    final candidates = japaneseAddressCandidates(
      [
        [const AddressGlyph('豊橋', Rect.fromLTRB(20, 10, 60, 30))],
        [const AddressGlyph('北山', Rect.fromLTRB(20, 60, 60, 80))],
      ],
      200,
      100,
      dictionary: dictionary,
    );
    expect(candidates, hasLength(2));
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      addresses: editor.FakeDetector()..candidates.addAll(candidates),
      includeOtherCandidates: false,
    );
    expect(editor.overlay(tester).selectedCandidates, candidates.toSet());
    await editor.tapPixel(tester, const Offset(40, 20));
    expect(editor.overlay(tester).selectedCandidates, {candidates.last});
    await editor.tapPixel(tester, const Offset(40, 20));
    expect(editor.overlay(tester).selectedCandidates, candidates.toSet());
    await editor.tapPixel(tester, const Offset(40, 20));
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, [candidates.last.region]);
    await editor.tapText(tester, '写真に保存');
    expect(saver.received, same(processor.jpeg));
  });
  testWidgets('continuous address and trailing text save independently', (
    tester,
  ) async {
    const text = '愛知県豊橋市大岩町字北山1-2-3ABC棟';
    final candidates = japaneseAddressCandidates(
      [
        [
          for (var i = 0; i < text.length; i++)
            AddressGlyph(text[i], Rect.fromLTWH(10 + i * 7, 30, 7, 20)),
        ],
      ],
      200,
      100,
      dictionary: dictionary,
    );
    expect(candidates, hasLength(6));
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      addresses: editor.FakeDetector()..candidates.addAll(candidates),
      includeOtherCandidates: false,
    );
    expect(editor.overlay(tester).selectedCandidates, candidates.toSet());
    // Reveal only the city; the town, aza, lot and trailing text remain masked.
    await editor.tapPixel(tester, candidates[1].region.toRect().center);
    final selected = candidates.where((c) => c != candidates[1]).toList();
    expect(editor.overlay(tester).selectedCandidates, selected.toSet());
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, selected.map((c) => c.region));
    await editor.tapText(tester, '写真に保存');
    expect(saver.received, same(processor.jpeg));
  });
  testWidgets(
    'standalone components toggle independently and save the selection',
    (tester) async {
      final candidates = japaneseAddressCandidates(
        [
          [const AddressGlyph('東京都', Rect.fromLTRB(20, 10, 70, 25))],
          [const AddressGlyph('横浜市', Rect.fromLTRB(20, 40, 70, 55))],
          [const AddressGlyph('1-2-3', Rect.fromLTRB(20, 70, 70, 85))],
        ],
        200,
        100,
      );
      final detector = editor.FakeDetector()..candidates.addAll(candidates);
      final processor = editor.FakeProcessor(200, 100);
      final saver = editor.FakeSaver();
      await editor.open(
        tester,
        processor,
        saver,
        addresses: detector,
        includeOtherCandidates: false,
      );
      expect(editor.overlay(tester).selectedCandidates, candidates.toSet());
      await editor.tapPixel(tester, const Offset(45, 47));
      expect(editor.overlay(tester).selectedCandidates, {
        candidates.first,
        candidates.last,
      });
      await editor.tapPixel(tester, const Offset(45, 47));
      expect(editor.overlay(tester).selectedCandidates, candidates.toSet());
      await editor.tapPixel(tester, const Offset(45, 47));
      await editor.tapText(tester, '保存前に確認');
      expect(processor.received, [
        candidates.first.region,
        candidates.last.region,
      ]);
      await editor.tapText(tester, '写真に保存');
      expect(saver.received, same(processor.jpeg));
    },
  );
  testWidgets('only addresses are scanned, auto-hidden and passed to save', (
    tester,
  ) async {
    final address = editor.candidate(
      CandidateKind.address,
      const Rect.fromLTRB(20, 20, 90, 40),
    );
    final detector = editor.FakeDetector()
      ..candidates.addAll([
        address,
        editor.candidate(
          CandidateKind.text,
          const Rect.fromLTRB(110, 20, 190, 40),
        ),
        editor.candidate(
          CandidateKind.face,
          const Rect.fromLTRB(110, 50, 190, 90),
        ),
      ]);
    final texts = editor.FakeDetector();
    final objects = editor.FakeDetector();
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      addresses: detector,
      texts: texts,
      objects: objects,
      includeOtherCandidates: false,
    );
    expect(detector.calls, 1);
    expect(texts.calls, 0);
    expect(objects.calls, 0);
    expect(editor.overlay(tester).candidates, [address]);
    expect(editor.painter(tester).regions, [address.region]);
    await editor.tapPixel(tester, const Offset(50, 30));
    expect(editor.painter(tester).regions, isEmpty);
    await editor.tapPixel(tester, const Offset(50, 30));
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, [address.region]);
    await editor.tapText(tester, '写真に保存');
    expect(saver.calls, 1);
  });

  testWidgets('save waits for OCR and retry preserves a revealed address', (
    tester,
  ) async {
    final address = editor.candidate(
      CandidateKind.address,
      const Rect.fromLTRB(20, 20, 90, 40),
    );
    final detector = editor.FakeDetector()
      ..pending = Completer<RegionDetection>();
    final processor = editor.FakeProcessor(200, 100);
    await editor.open(
      tester,
      processor,
      editor.FakeSaver(),
      addresses: detector,
      includeOtherCandidates: false,
      settle: false,
    );
    await tester.tap(find.byTooltip('保存前に確認'));
    await tester.pump();
    expect(processor.received, isNull);
    detector.pending!.complete(
      RegionDetection(candidates: [address], partial: true),
    );
    await tester.pumpAndSettle();
    await editor.tapPixel(tester, const Offset(50, 30));
    detector.pending = null;
    // A retry returns new objects with the same geometry.
    detector.candidates.add(
      RegionCandidate(kind: CandidateKind.address, region: address.region),
    );
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(editor.painter(tester).regions, isEmpty);
    expect(editor.overlay(tester).candidates, hasLength(1));
    await editor.tapText(tester, '保存前に確認');
    expect(processor.received, isEmpty);
  });
}
