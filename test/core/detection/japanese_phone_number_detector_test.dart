import 'package:camereon/core/detection/japanese_phone_number_detector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:ui';

List<PhoneGlyph> line(String text, {double x = 10, double y = 10}) => [
  for (var i = 0; i < text.length; i++)
    (text: text[i], bounds: Rect.fromLTWH(x + i * 10, y, 10, 16)),
];

void main() {
  for (final text in [
    '03-0000-1234',
    '06-1234-5678',
    '098-123-4567',
    '0312345678',
    '090-0000-1234',
    '07012345678',
    '08012345678',
    '06012345678',
    '050-1234-5678',
    '0120-123-456',
    '0570-123-456',
    '0800-123-4567',
    '０９０－００００－１２３４',
    '090 0000 1234',
    '(03) 0000-1234',
    '+81 90 0000 1234',
    '+81-3-0000-1234',
    '+81 (0)90-0000-1234',
    '電話番号:090-0000-1234',
    'TEL090-0000-1234',
  ]) {
    test('automatically masks a full Japanese format: $text', () {
      final found = japanesePhoneNumberCandidates([line(text)], 1000, 300);
      expect(found, hasLength(1));
      expect(found.single.automaticallySelected, isTrue);
    });
  }
  for (final text in [
    '03)0000(1234',
    '09000001234@example.com',
    'user@09000001234.jp',
    '1234567890',
    '2026-11-17',
    '20261117',
    '100-0001',
    '〒1000001',
    '0901234567',
    '090123456789',
    '0120-123-4567',
    '0800-12-3456',
    '090-123-45678',
    '+1 212-000-1234',
    '+81 090-0000-1234',
    'ID:09000001234',
    '管理番号:03-0000-1234',
    '注文番号09000001234',
    'FAX:03-0000-1234',
    'ABC09000001234Z',
    '109000001234',
    '電話番号',
    'TEL:20261117',
    'TEL:12345',
    '123-4567',
  ]) {
    test('does not mask a non-phone or incomplete unlabelled value: $text', () {
      expect(japanesePhoneNumberCandidates([line(text)], 1000, 300), isEmpty);
    });
  }
  test('only number glyphs are covered; TEL and recipient remain visible', () {
    const text = 'TEL:03-0000-1234 名前';
    final found = japanesePhoneNumberCandidates([line(text)], 1000, 300);
    expect(found.single.region.toRect(), const Rect.fromLTRB(47, 7, 173, 29));
  });
  test('a labelled local number is optional, never auto-hidden', () {
    final found = japanesePhoneNumberCandidates(
      [line('TEL:123-4567')],
      1000,
      300,
    );
    expect(found, hasLength(1));
    expect(found.single.automaticallySelected, isFalse);
  });
  test('a label immediately above can support a local number', () {
    final found = japanesePhoneNumberCandidates(
      [line('電話番号'), line('12345678', y: 40)],
      1000,
      300,
    );
    expect(found.single.automaticallySelected, isFalse);
  });
  test('a distant label or another column cannot support a local number', () {
    for (final second in [
      line('12345678', y: 100),
      line('12345678', x: 400, y: 40),
    ]) {
      expect(
        japanesePhoneNumberCandidates([line('TEL'), second], 1000, 300),
        isEmpty,
      );
    }
  });
  test('nearby numeric columns are not concatenated into one phone number', () {
    expect(
      japanesePhoneNumberCandidates(
        [
          [...line('0900000'), ...line('1234', x: 400)],
        ],
        1000,
        300,
      ),
      isEmpty,
    );
  });
  test('multiple labelled fields produce separate masks', () {
    final found = japanesePhoneNumberCandidates(
      [line('TEL:03-0000-1234 携帯:090-0000-5678')],
      1000,
      300,
    );
    expect(found, hasLength(2));
    expect(found.every((c) => c.automaticallySelected), isTrue);
  });
  test('OCR groups containing several characters retain their coordinates', () {
    final found = japanesePhoneNumberCandidates(
      [
        [
          (text: 'TEL:', bounds: const Rect.fromLTRB(0, 0, 40, 20)),
          (text: '03-0000-1234', bounds: const Rect.fromLTRB(40, 0, 150, 20)),
        ],
      ],
      200,
      100,
    );
    expect(found.single.region.left, 37);
    expect(found.single.region.right, 153);
  });
}
