import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camereon/core/detection/japanese_address_detector.dart';
import 'package:camereon/core/detection/place_name_dictionary.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Uint8List bytes;
  late PlaceNameDictionary dictionary;
  setUpAll(() {
    bytes = File('assets/address_dictionary/names.bin').readAsBytesSync();
    dictionary = PlaceNameDictionary.fromBytes(bytes);
  });

  test('published binary matches its provenance checksum', () {
    final manifest = jsonDecode(
      File('assets/address_dictionary/manifest.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    expect(sha256.convert(bytes).toString(), manifest['binary_sha256']);
  });

  test('municipalities and aza have standalone unmarked aliases', () {
    for (final name in ['豊橋市', '豊橋', '横浜', '新宿', '津市', '大岩町', '字北山', '北山']) {
      expect(dictionary.contains(name), isTrue, reason: name);
    }
    expect(dictionary.contains(''), isFalse);
    expect(dictionary.contains('zzzz'), isFalse);
    expect(dictionary.matches('03-1234-5678 100-0001'), isEmpty);
  });

  test('single-character names retain only kanji', () {
    for (final name in ['ア', 'イ', 'ノ', 'ン', 'あ', 'の', 'A', '1']) {
      expect(dictionary.contains(name), isFalse, reason: name);
      expect(dictionary.matches(name), isEmpty, reason: name);
    }
    for (final name in ['津', '山']) {
      expect(dictionary.contains(name), isTrue, reason: name);
      final candidates = japaneseAddressCandidates(
        [
          [AddressGlyph(name, const Rect.fromLTWH(10, 10, 10, 16))],
        ],
        200,
        100,
        dictionary: dictionary,
      );
      expect(candidates, hasLength(1), reason: name);
    }
    bool isKanji(int code) =>
        (code >= 0x3400 && code <= 0x4dbf) ||
        (code >= 0x4e00 && code <= 0x9fff) ||
        (code >= 0xf900 && code <= 0xfaff) ||
        (code >= 0x20000 && code <= 0x323af);
    // Inspect all root terminals, including surrogate pairs, rather than only
    // checking sample names. Supplementary kanji are one Unicode character.
    final data = ByteData.sublistView(bytes);
    final nodes = data.getUint32(4, Endian.little);
    bool terminal(int node) =>
        data.getUint16(16 + node * 8 + 6, Endian.little) != 0;
    Iterable<(int, int)> children(int node) sync* {
      final offset = 16 + node * 8;
      final first = data.getUint32(offset, Endian.little);
      final count = data.getUint16(offset + 4, Endian.little);
      for (var i = first; i < first + count; i++) {
        final edge = 16 + nodes * 8 + i * 8;
        yield (
          data.getUint32(edge, Endian.little),
          data.getUint32(edge + 4, Endian.little),
        );
      }
    }

    for (final (unit, child) in children(0)) {
      if (terminal(child)) {
        expect(isKanji(unit), isTrue, reason: String.fromCharCode(unit));
      }
      if (unit >= 0xd800 && unit <= 0xdbff) {
        for (final (low, descendant) in children(child)) {
          if (low >= 0xdc00 && low <= 0xdfff) {
            if (terminal(descendant)) {
              final code = 0x10000 + ((unit - 0xd800) << 10) + low - 0xdc00;
              expect(isKanji(code), isTrue);
            }
          }
        }
      }
    }
  });

  test('longest matches keep continuous address components separate', () {
    const text = '愛知県豊橋市大岩町字北山';
    expect(
      dictionary.matches(text).map((s) => text.substring(s.start, s.end)),
      ['愛知県', '豊橋市', '大岩町', '字北山'],
    );
    const address = '${text}1-2-3ABC棟';
    final candidates = japaneseAddressCandidates(
      [
        [
          for (var i = 0; i < address.length; i++)
            AddressGlyph(address[i], Rect.fromLTWH(10 + i * 10, 10, 10, 16)),
        ],
      ],
      1000,
      200,
      dictionary: dictionary,
    );
    expect(candidates, hasLength(6));
    expect(candidates.map((c) => c.region.left), [8, 38, 68, 98, 128, 178]);
  });

  test('bare names work without another address elsewhere in the image', () {
    for (final text in ['豊橋', '北山']) {
      final candidates = japaneseAddressCandidates(
        [
          [
            for (var i = 0; i < text.length; i++)
              AddressGlyph(text[i], Rect.fromLTWH(10 + i * 10, 10, 10, 16)),
          ],
        ],
        200,
        100,
        dictionary: dictionary,
      );
      expect(candidates, hasLength(1), reason: text);
      expect(
        candidates.single.region.toRect(),
        const Rect.fromLTRB(8, 8, 32, 28),
      );
    }
  });

  test('repeated names and UTF16 positions remain aligned', () {
    const text = '😀豊橋 北山\n豊橋';
    expect(dictionary.matches(text).toList(), [
      (start: 2, end: 4),
      (start: 5, end: 7),
      (start: 8, end: 10),
    ]);
    expect(dictionary.matches('豊\n橋'), isNot(contains((start: 0, end: 3))));
  });

  test('corrupt assets are rejected before traversal', () {
    expect(
      () => PlaceNameDictionary.fromBytes(Uint8List(4)),
      throwsFormatException,
    );
    expect(
      () => PlaceNameDictionary.fromBytes(
        Uint8List.sublistView(bytes, 0, bytes.length - 1),
      ),
      throwsFormatException,
    );
    final corrupt = Uint8List.fromList(bytes);
    ByteData.sublistView(corrupt).setUint32(16, 0xffffffff, Endian.little);
    expect(() => PlaceNameDictionary.fromBytes(corrupt), throwsFormatException);
  });

  test('bundled dictionary loads and caches without network', () async {
    final first = await PlaceNameDictionary.load();
    expect(first.contains('北山'), isTrue);
    expect(await PlaceNameDictionary.load(), same(first));
  });
}
