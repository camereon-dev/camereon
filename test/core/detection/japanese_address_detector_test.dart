import 'dart:async';

import 'package:camereon/core/detection/address_detection_mode.dart';
import 'package:camereon/core/detection/place_name_dictionary.dart';
import 'package:camereon/core/detection/japanese_address_detector.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/core/photo/photo_images.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

List<AddressGlyph> glyphs(String text, {double y = 10, double x = 10}) => [
  for (var i = 0; i < text.length; i++)
    AddressGlyph(text[i], Rect.fromLTWH(x + i * 10, y, 10, 16)),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'address only masks numbered addresses and leaves other mentions visible',
    () async {
      final dictionary = await PlaceNameDictionary.load();
      final candidates = japaneseAddressCandidates(
        [
          glyphs('東京都新宿区西新宿2-8-1で開催'),
          glyphs('新宿区のイベント', y: 40),
          glyphs('西新宿', y: 70),
          glyphs('西新宿2-8-1', y: 130),
        ],
        1000,
        200,
        dictionary: dictionary,
        mode: AddressDetectionMode.addressOnly,
      );
      expect(candidates.map((c) => c.region.top), [8, 128]);
      expect(candidates.first.region.right, 12 + '東京都新宿区西新宿2-8-1'.length * 10);
    },
  );
  group('nearby address fields in address-only mode', () {
    late PlaceNameDictionary dictionary;
    setUpAll(() async {
      dictionary = await PlaceNameDictionary.load();
    });
    List<Rect> detect(List<List<AddressGlyph>> lines) => [
      for (final c in japaneseAddressCandidates(
        lines,
        1000,
        300,
        mode: AddressDetectionMode.addressOnly,
        dictionary: dictionary,
      ))
        c.region.toRect(),
    ];

    test('campus address wraps from the right edge to a left-aligned lot', () {
      const locality = '沖縄県宜野湾市字喜友名';
      expect(
        detect([
          glyphs('キャンパス：'),
          glyphs('1076番地.⑤国立大学法人', x: 80, y: 32),
          glyphs('詳細案内', y: 90),
          glyphs(locality, x: 700),
        ]),
        [
          const Rect.fromLTRB(78, 30, 142, 50),
          Rect.fromLTRB(698, 8, 702 + locality.length * 10, 28),
        ],
      );
      for (final postal in [true, false]) {
        final boxes = detect([
          glyphs('キャンパス：'),
          [
            if (postal) ...glyphs('〒123-4567', x: 600),
            ...glyphs(locality, x: 700),
          ],
          glyphs('1076番地', x: 80, y: 32),
          glyphs('大学の案内', x: 180, y: 32),
        ]);
        expect(boxes, [
          if (postal) const Rect.fromLTRB(598, 8, 692, 28),
          Rect.fromLTRB(698, 8, 702 + locality.length * 10, 28),
          const Rect.fromLTRB(78, 30, 142, 50),
        ]);
      }
      expect(detect([glyphs('〒123-4567沖縄県宜野湾市字喜友名')]), hasLength(2));
      expect(
        detect([glyphs(locality, x: 700), glyphs('123円', y: 32)]),
        isEmpty,
      );
    });
    test('continues through nearby fields and stops at notes', () {
      final boxes = detect([
        glyphs('東京都新宿区西新宿2-8-1'),
        glyphs('字北山', y: 32),
        glyphs('123番地で開催', y: 54),
        glyphs('備考', y: 76),
        glyphs('北山', y: 98),
      ]);
      expect(boxes.map((b) => b.top), [8, 30, 52]);
      expect(boxes.last.right, 12 + '123番地'.length * 10);
    });

    test('pairs a place and a lot on adjacent lines with supporting clues', () {
      for (final (name, lot) in [('大字山田', '123'), ('北山', '12-3')]) {
        expect(detect([glyphs(name), glyphs(lot, y: 32)]), hasLength(2));
      }
      for (final lot in ['123', '123円', '2026-11-24']) {
        expect(detect([glyphs('北山'), glyphs(lot, y: 32)]), isEmpty);
      }
    });

    test('address labels identify values beside or below them', () {
      expect(detect([glyphs('住所：北山')]).single.left, 38);
      expect(detect([glyphs('番地'), glyphs('123', y: 32)]).single.top, 30);
    });

    test('checks preceding fields and neighboring fields in the same row', () {
      expect(detect([glyphs('北山'), glyphs('西新宿2-8-1', y: 32)]), hasLength(2));
      expect(
        detect([
          [...glyphs('西新宿2-8-1'), ...glyphs('字北山', x: 110)],
        ]),
        hasLength(2),
      );
    });

    test('rejects distant rows, adjacent columns and other fields', () {
      expect(detect([glyphs('字北山'), glyphs('123番地', y: 150)]), isEmpty);
      expect(detect([glyphs('字北山'), glyphs('123番地', x: 180, y: 32)]), isEmpty);
      expect(
        detect([
          [...glyphs('北山'), ...glyphs('12-3', x: 180)],
        ]),
        isEmpty,
      );
      expect(
        detect([
          glyphs('東京都新宿区西新宿2-8-1'),
          glyphs('電話', y: 32),
          glyphs('123', y: 54),
        ]),
        hasLength(1),
      );
    });
  });
  for (final text in [
    '東京都千代田区千代田1-1',
    '東京都新宿区西新宿２丁目８番１号',
    '大阪府大阪市北区中之島1丁目3番20号',
    '北海道札幌市中央区北一条西2丁目',
    '千代田区丸の内一丁目9番1号',
    '京都府京都市中京区寺町通御池上る上本能寺前町488番地',
    '沖縄県那覇市泉崎1-1-1',
    '東京都新宿区西新宿2－8－1',
    '東京都千代田区丸の内1-1-1サンプルビル201号室',
  ]) {
    test('recognizes Japanese address: $text', () {
      final found = japaneseAddressCandidates([glyphs(text)], 1000, 200);
      expect(found, isNotEmpty);
      expect(found.every((c) => c.kind == CandidateKind.address), isTrue);
      expect(found.first.region.left, 8);
      expect(found.last.region.right, 10 + text.length * 10 + 2);
    });
  }
  for (final mode in [
    AddressDetectionMode.placeNames,
    AddressDetectionMode.addressOnly,
  ]) {
    for (final text in [
      '〒100-0001',
      '100-0001',
      '〒１００－０００１',
      '1000001',
      '〒1000001',
    ]) {
      test('postal code is one complete mask in ${mode.name}: $text', () {
        final found = japaneseAddressCandidates(
          [glyphs(text)],
          1000,
          200,
          mode: mode,
        );
        expect(found, hasLength(1));
        expect(found.single.region.left, 8);
        expect(found.single.region.right, 12 + text.length * 10);
      });
    }
    for (final text in [
      '0312345678',
      '090-1234-5678',
      '0120-123-4567',
      '12345678',
      'ABC1234567Z',
    ]) {
      test(
        'does not take postal code from longer number in ${mode.name}: $text',
        () {
          expect(
            japaneseAddressCandidates([glyphs(text)], 1000, 200, mode: mode),
            isEmpty,
          );
        },
      );
    }
  }
  test('postal code and following address are separate', () {
    const text = '〒100-0001東京都';
    final found = japaneseAddressCandidates([glyphs(text)], 1000, 200);
    expect(found, hasLength(2));
    expect(found.map((c) => c.region.left), [8, 98]);
    expect(found.map((c) => c.region.right), [102, 132]);
  });
  for (final text in [
    '文字',
    '数字',
    '漢字',
    '字を書く',
    '字の大きさ',
    '大字名',
    '山田花子様',
    'お届け先',
    '電話03-1234-5678',
    '2026年11月10日',
  ]) {
    test('does not offer unrelated text: $text', () {
      expect(japaneseAddressCandidates([glyphs(text)], 1000, 200), isEmpty);
    });
  }
  test(
    'masks only the address span, excluding heading, recipient and phone',
    () {
      const address = '東京都千代田区千代田1-1';
      final found = japaneseAddressCandidates(
        [glyphs('住所:$address 電話:03-1234-5678 山田花子様')],
        1000,
        200,
      );
      expect(found, hasLength(4));
      expect(found.first.region.left, 38);
      expect(found.last.region.right, 10 + (3 + address.length) * 10 + 2);
    },
  );
  test('wrapped address produces separate line masks', () {
    final found = japaneseAddressCandidates(
      [glyphs('東京都千代田区'), glyphs('千代田1-1', y: 30)],
      1000,
      200,
    );
    expect(found, hasLength(4));
    expect(found.first.region.bottom, lessThanOrEqualTo(found.last.region.top));
  });
  test('distant lines keep standalone components without bridging the gap', () {
    final found = japaneseAddressCandidates(
      [glyphs('東京都'), glyphs('横浜市', y: 80), glyphs('2丁目8番1号', y: 150)],
      1000,
      200,
    );
    expect(found, hasLength(3));
    expect(found.map((c) => c.region.top), [8, 78, 148]);
    expect(found.every((c) => c.region.height == 20), isTrue);
  });
  for (final text in [
    '東京都',
    '北海道',
    '京都府',
    '神奈川県',
    '横浜市',
    '新宿区',
    '白川村',
    '葉山町',
    '田村市',
    '市川市',
    '横浜市中区',
    '字北山',
    '大字上野',
    '小字中原',
    '字北山123番地',
    '大字上野1-2-3',
    '123番地',
    '一丁目二番三号',
    '２丁目８番１号',
    '1-2-3',
    '1-2',
  ]) {
    test('recognizes standalone component: $text', () {
      final found = japaneseAddressCandidates([glyphs(text)], 1000, 200);
      expect(found, isNotEmpty);
      expect(found.first.region.left, 8);
      expect(found.last.region.right, 12 + text.length * 10);
    });
  }
  for (final text in ['123', '2026-11-10', '03-1234-5678', '中村', '市町村']) {
    test(
      'does not interpret ambiguous numbers and headings as standalone lots: $text',
      () {
        expect(japaneseAddressCandidates([glyphs(text)], 1000, 200), isEmpty);
      },
    );
  }
  test('labelled bare lot number excludes the label', () {
    final found = japaneseAddressCandidates([glyphs('番地:123')], 1000, 200);
    expect(found, hasLength(1));
    expect(found.single.region.toRect(), const Rect.fromLTRB(38, 8, 72, 28));
  });
  test('separate components on the same line retain independent boxes', () {
    final found = japaneseAddressCandidates(
      [glyphs('東京都 横浜市 1-2-3')],
      1000,
      200,
    );
    expect(found, hasLength(3));
    expect(found.map((c) => c.region.left), [8, 48, 88]);
  });
  test('prefecture within prose does not hide surrounding words', () {
    final found = japaneseAddressCandidates(
      [glyphs('本日の東京都の天気は晴れ')],
      1000,
      200,
    );
    expect(found, hasLength(1));
    expect(found.single.region.toRect(), const Rect.fromLTRB(38, 8, 72, 28));
  });

  for (final entry in <String, List<String>>{
    '愛知県豊橋市大岩町字北山': ['愛知県', '豊橋市', '大岩町', '字北山'],
    '愛知県豊橋市大岩町字北山1-2-3サンライズA棟201': [
      '愛知県',
      '豊橋市',
      '大岩町',
      '字北山',
      '1-2-3',
      'サンライズA棟201',
    ],
    '東京都新宿区西新宿2丁目8番1号ABCレジデンス': ['東京都', '新宿区', '西新宿', '2丁目8番1号', 'ABCレジデンス'],
    '豊橋市大岩町字北山': ['豊橋市', '大岩町', '字北山'],
    '大字上野字北山123番地コーポ青空': ['大字上野', '字北山', '123番地', 'コーポ青空'],
    '横浜市中区': ['横浜市', '中区'],
  }.entries) {
    test('splits continuous address: ${entry.key}', () {
      final found = japaneseAddressCandidates([glyphs(entry.key)], 1000, 200);
      final pieces = [
        for (final c in found)
          entry.key.substring(
            (c.region.left + 2 - 10) ~/ 10,
            (c.region.right - 2 - 10) ~/ 10,
          ),
      ];
      expect(pieces, entry.value);
    });
  }
  test('trailing text stops at other field labels', () {
    const text = '愛知県豊橋市大岩町字北山1-2-3ABC棟電話03-1234-5678';
    final found = japaneseAddressCandidates([glyphs(text)], 1000, 200);
    expect(found.last.region.right, 12 + text.indexOf('電話') * 10);
  });

  for (final entry in <String, List<String>>{
    '新宿区役所からのお知らせ': ['新宿区'],
    '今日の豊橋市の天気': ['豊橋市'],
    '訪問先は豊橋市と豊川市です': ['豊橋市', '豊川市'],
    '開催地:白川村、葉山町、横浜市中区': ['白川村', '葉山町', '横浜市', '中区'],
    '字北山の周辺案内': ['字北山'],
    '大字上野付近の地図': ['大字上野'],
    '小字中原への道': ['小字中原'],
    '東京都と愛知県の案内': ['東京都', '愛知県'],
  }.entries) {
    test('hides mentions inside prose: ${entry.key}', () {
      final found = japaneseAddressCandidates([glyphs(entry.key)], 1000, 200);
      expect([
        for (final c in found)
          entry.key.substring(
            (c.region.left + 2 - 10) ~/ 10,
            (c.region.right - 2 - 10) ~/ 10,
          ),
      ], entry.value);
    });
  }
  test('hides all repeated known names including aza without its marker', () {
    final found = japaneseAddressCandidates(
      [glyphs('字北山'), glyphs('北山の案内', y: 50), glyphs('字北山の地図', y: 90)],
      1000,
      200,
    );
    expect(found, hasLength(3));
    expect(found.map((c) => c.region.right), [42, 32, 42]);
  });

  const channel = MethodChannel('test/japanese_ocr');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final photo = SourcePhoto(
    bytes: img.encodePng(img.Image(width: 400, height: 200)),
    width: 400,
    height: 200,
  );
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  test('native OCR boxes produce address candidates', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'lines': [
          for (final line in [glyphs('東京都千代田区千代田1-1')])
            [
              for (final g in line)
                {
                  'text': g.text,
                  'box': [
                    g.bounds.left,
                    g.bounds.top,
                    g.bounds.right,
                    g.bounds.bottom,
                  ],
                },
            ],
        ],
      },
    );
    final result = await JapaneseAddressDetector(channel: channel)
        .detect(photo);
    expect(result.candidates, hasLength(4));
    expect(
      result.candidates.every((c) => c.kind == CandidateKind.address),
      isTrue,
    );
  });
  test('rejects malformed and out-of-image OCR geometry', () async {
    for (final box in [
      [0, 0, 401, 20],
      [10, 10, 0, 0],
      [double.nan, 0, 10, 20],
    ]) {
      messenger.setMockMethodCallHandler(
        channel,
        (_) async => {
          'lines': [
            [
              {'text': '住所', 'box': box},
            ],
          ],
        },
      );
      await expectLater(
        JapaneseAddressDetector(channel: channel).detect(photo),
        throwsA(isA<RegionDetectionException>()),
      );
    }
  });
  test('native call that never returns fails instead of hanging', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) => Completer<Object?>().future,
    );
    await expectLater(
      JapaneseAddressDetector(
        channel: channel,
        nativeTimeout: const Duration(milliseconds: 50),
      ).detect(photo),
      throwsA(isA<RegionDetectionException>()),
    );
  });
}
