import 'package:camereon/core/detection/japanese_phone_number_detector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:ui';

List<PhoneGlyph> line(String text, {double x = 10, double y = 10}) => [
  for (var i = 0; i < text.length; i++)
    (text: text[i], bounds: Rect.fromLTWH(x + i * 10, y, 10, 16)),
];

void main() {
  for (final text in [
    '03)0000(1234',
    '1234567890',
    '4111 1111 1111 1111',
    '4901234567894',
    '20261117123045',
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
    '109000001234',
    '098-895-8012',
    '080-623-1234',
    '123456789',
    '0501234',
    '06012345',
    '0701234',
    '08012345',
    '0901234',
    'O98-895-8o12',
    '０９８－８９５－８Ｏ１２',
    '+81 3 0000 1234',
    '＋８１ ９０ ００００ １２３４',
    '03-0000-1234',
    '03 0000 1234',
    '06 0000-1234',
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
    test('automatically masks a broad numeric candidate: $text', () {
      final found = japanesePhoneNumberCandidates([line(text)], 1000, 300);
      expect(found, hasLength(1));
      expect(found.single.automaticallySelected, isTrue);
    });
  }
  for (final text in [
    '09000001234@example.com',
    'user@09000001234.jp',
    '2026-11-17',
    '20261117',
    '100-0001',
    '〒1000001',
    'ABC09000001234Z',
    '電話番号',
    'TEL:20261117',
    'TEL:12345',
    '123-4567',
    '090123',
    'O98-895',
    'OOO-OOOO-OOOO',
    'FOO0988958012',
  ]) {
    test('does not mask a short, ambiguous or embedded value: $text', () {
      expect(japanesePhoneNumberCandidates([line(text)], 1000, 300), isEmpty);
    });
  }
  test('only number glyphs are covered; TEL and recipient remain visible', () {
    const text = 'TEL:03-0000-1234 名前';
    final found = japanesePhoneNumberCandidates([line(text)], 1000, 300);
    expect(found.single.region.toRect(), const Rect.fromLTRB(47, 7, 173, 29));
  });
  test('spaces between OCR glyph bounds do not split a printed number', () {
    List<PhoneGlyph> glyphs(
      String text,
      double x,
      double advance,
      double height,
      double width,
    ) => [
      for (final (i, char) in text.split('').indexed)
        (
          text: char,
          bounds: Rect.fromLTWH(
            x + i * advance,
            10,
            char == '1' && advance == 20 ? 10 : width,
            height,
          ),
        ),
    ];
    final local = japanesePhoneNumberCandidates(
      [
        [...line('TEL:'), ...glyphs('12345678', 54, 20, 26, 16)],
      ],
      1000,
      300,
    );
    expect(local.single.automaticallySelected, isFalse);

    final international = japanesePhoneNumberCandidates(
      [
        [
          ...glyphs('+81', 10, 36, 35, 19),
          ...glyphs('90', 126, 36, 35, 19),
          ...glyphs('0000', 206, 36, 35, 19),
          ...glyphs('9876', 358, 36, 35, 19),
        ],
      ],
      1000,
      300,
    );
    expect(international.single.automaticallySelected, isTrue);
    expect(international.single.region.left, 4);
    expect(international.single.region.right, 491);
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
  test('distant numeric columns are not concatenated into one mask', () {
    expect(
      japanesePhoneNumberCandidates(
        [
          [...line('1234567'), ...line('1234', x: 400)],
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
  test(
    'separated mobile fragment is masked without covering the distant column',
    () {
      final found = japanesePhoneNumberCandidates(
        [
          [...line('0900000'), ...line('1234', x: 400)],
        ],
        1000,
        300,
      );
      expect(found, hasLength(1));
      expect(found.single.automaticallySelected, isTrue);
      expect(found.single.region.right, lessThan(100));
    },
  );
  test('space-separated digits can share one OCR bounding box', () {
    const bounds = Rect.fromLTRB(40, 10, 150, 30);
    final found = japanesePhoneNumberCandidates(
      [
        [(text: '03 0000 1234', bounds: bounds)],
      ],
      200,
      100,
    );
    expect(found.single.automaticallySelected, isTrue);
    expect(found.single.region.toRect(), bounds.inflate(3));
  });
  test('nearby 3+ digit observations join even when OCR order is reversed', () {
    for (final fragments in [
      [line('098', x: 10), line('895', x: 50), line('8012', x: 90)],
      [line('8012', x: 90), line('098', x: 10), line('895', x: 50)],
    ]) {
      final found = japanesePhoneNumberCandidates(fragments, 1000, 300);
      expect(found, hasLength(1));
      expect(found.single.automaticallySelected, isTrue);
      expect(found.single.region.left, 7);
      expect(found.single.region.right, 133);
    }
  });
  test('space-separated fragments use original glyph coordinates', () {
    final found = japanesePhoneNumberCandidates(
      [line('098 895 8012')],
      1000,
      300,
    );
    expect(found, hasLength(1));
    expect(found.single.region.toRect(), const Rect.fromLTRB(7, 7, 133, 29));
  });
  test('separate +81 and short mobile or area prefixes can join', () {
    for (final prefix in ['90', '3']) {
      final found = japanesePhoneNumberCandidates(
        [
          line('+81', x: 10),
          line(prefix, x: 50),
          line('0000', x: 50 + prefix.length * 10 + 10),
          line('1234', x: 50 + prefix.length * 10 + 60),
        ],
        1000,
        300,
      );
      expect(found, hasLength(1));
      expect(found.single.automaticallySelected, isTrue);
      expect(found.single.region.left, 7);
    }
  });
  test('split 03 and 06 area codes join nearby four-digit fragments', () {
    for (final area in ['03', '06']) {
      final found = japanesePhoneNumberCandidates(
        [line('5678', x: 90), line(area, x: 10), line('1234', x: 40)],
        1000,
        300,
      );
      expect(found.single.automaticallySelected, isTrue);
      expect(found.single.region.toRect(), const Rect.fromLTRB(7, 7, 133, 29));
    }
  });
  test('same-row joining does not combine another row or distant column', () {
    for (final fragments in [
      [line('123', x: 10), line('456789', x: 50, y: 40)],
      [line('123', x: 10), line('456789', x: 100)],
      [line('123', x: 10), line('456789', x: 50, y: 20)],
    ]) {
      expect(japanesePhoneNumberCandidates(fragments, 1000, 300), isEmpty);
    }
  });
  test('arbitrary fragments shorter than 3 digits do not join', () {
    for (final fragments in [
      [line('12', x: 10), line('3456789', x: 40)],
      [line('1234567', x: 10), line('89', x: 90)],
      [line('12 3456789')],
    ]) {
      expect(japanesePhoneNumberCandidates(fragments, 1000, 300), isEmpty);
    }
  });
  test('international format does not bridge distant positions', () {
    final found = japanesePhoneNumberCandidates(
      [
        line('+81'),
        line('90', x: 300),
        line('0000', x: 330),
        line('1234', x: 380),
      ],
      1000,
      300,
    );
    expect(found, isEmpty);
  });
}
