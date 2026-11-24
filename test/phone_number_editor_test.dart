import 'package:camereon/core/detection/japanese_phone_number_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/photo_editor.dart' as editor;

void main() {
  final address = editor.candidate(
    CandidateKind.address,
    const Rect.fromLTRB(10, 10, 80, 25),
  );
  final phone = PhoneNumberCandidate(
    region: editor.region(const Rect.fromLTRB(10, 40, 90, 55)),
    automaticallySelected: true,
  );
  final optional = PhoneNumberCandidate(
    region: editor.region(const Rect.fromLTRB(110, 70, 190, 85)),
    automaticallySelected: false,
  );

  testWidgets(
    'address and full phone auto-hide; optional phone toggles and saves',
    (tester) async {
      final processor = editor.FakeProcessor(200, 100);
      final saver = editor.FakeSaver();
      await editor.open(
        tester,
        processor,
        saver,
        includeOtherCandidates: false,
        addresses: editor.FakeDetector()
          ..candidates.addAll([address, phone, optional]),
      );
      expect(editor.overlay(tester).candidates, [address, phone, optional]);
      expect(editor.overlay(tester).selectedCandidates, {address, phone});
      await editor.tapPixel(tester, phone.region.toRect().center);
      expect(editor.overlay(tester).selectedCandidates, {address});
      await editor.tapPixel(tester, phone.region.toRect().center);
      expect(editor.overlay(tester).selectedCandidates, {address, phone});
      await editor.tapPixel(tester, optional.region.toRect().center);
      expect(editor.overlay(tester).selectedCandidates, {
        address,
        phone,
        optional,
      });
      await editor.tapText(tester, '取り消す');
      expect(editor.overlay(tester).selectedCandidates, {address, phone});
      await editor.tapKind(tester, CandidateKind.phone);
      expect(editor.overlay(tester).selectedCandidates, {
        address,
        phone,
        optional,
      });
      await editor.tapText(tester, '写真に保存');
      expect(processor.received, [
        address.region,
        phone.region,
        optional.region,
      ]);
      expect(saver.calls, 1);
    },
  );

  testWidgets('retry does not re-hide a phone that the user revealed', (
    tester,
  ) async {
    final detector = editor.FakeDetector()..partial = true;
    detector.candidates.addAll([address, phone, optional]);
    await editor.open(
      tester,
      editor.FakeProcessor(200, 100),
      editor.FakeSaver(),
      includeOtherCandidates: false,
      addresses: detector,
    );
    await editor.tapPixel(tester, phone.region.toRect().center);
    detector.partial = false;
    detector.candidates[1] = PhoneNumberCandidate(
      region: editor.region(const Rect.fromLTRB(11, 40, 91, 55)),
      automaticallySelected: true,
    );
    await editor.tapText(tester, '一部を検出できませんでした');
    expect(detector.calls, 2);
    expect(editor.overlay(tester).candidates, hasLength(3));
    expect(editor.overlay(tester).selectedCandidates, {address});
  });

  testWidgets('initial masks cover full numbers but not optional ones', (
    tester,
  ) async {
    final processor = editor.FakeProcessor(200, 100);
    final saver = editor.FakeSaver();
    await editor.open(
      tester,
      processor,
      saver,
      includeOtherCandidates: false,
      addresses: editor.FakeDetector()
        ..candidates.addAll([address, phone, optional]),
    );
    expect(processor.received, isNull);
    await editor.tapText(tester, '写真に保存');
    expect(processor.received, [address.region, phone.region]);
    expect(saver.calls, 1);
  });

  testWidgets(
    'number setting off keeps detected frames available for manual masking',
    (tester) async {
      final processor = editor.FakeProcessor(200, 100);
      await editor.open(
        tester,
        processor,
        editor.FakeSaver(),
        includeOtherCandidates: false,
        autoHideKinds: {CandidateKind.address, CandidateKind.face},
        addresses: editor.FakeDetector()
          ..candidates.addAll([address, phone, optional]),
      );
      expect(editor.overlay(tester).candidates, [address, phone, optional]);
      expect(editor.overlay(tester).selectedCandidates, {address});

      await editor.tapPixel(tester, phone.region.toRect().center);
      await editor.tapText(tester, '写真に保存');
      expect(processor.received, [address.region, phone.region]);
    },
  );
}
