import 'package:flutter/services.dart';

import '../photo/hide_region.dart';
import '../photo/photo_images.dart';
import 'address_detection_mode.dart';
import 'region_detector.dart';
import 'place_name_dictionary.dart';
import 'japanese_phone_number_detector.dart';

/// Shared Japanese OCR for address/phone regions. Text is never logged or stored.
class JapaneseAddressDetector implements RegionDetector {
  JapaneseAddressDetector({
    MethodChannel? channel,
    this.addressMode = AddressDetectionMode.placeNames,
    this._nativeTimeout = const Duration(seconds: 60),
  }) : _channel = channel ?? const MethodChannel('dev.camereon/japanese_ocr');
  final AddressDetectionMode addressMode;
  final MethodChannel _channel;
  final Duration _nativeTimeout;
  bool _working = false;

  @override
  Future<RegionDetection> detect(SourcePhoto photo) async {
    if (_working) throw const RegionDetectionException();
    _working = true;
    try {
      final dictionary = addressMode == AddressDetectionMode.off
          ? null
          : await PlaceNameDictionary.load();
      final pixels = await rawThumbnail(photo, 2560);
      final response = await _channel
          .invokeMapMethod<String, dynamic>('detect', {
            'bytes': pixels.bytes,
            'width': pixels.width,
            'height': pixels.height,
          })
          .timeout(
            _nativeTimeout,
            onTimeout: () => throw const RegionDetectionException(),
          );
      if (response == null ||
          response['lines'] is! List ||
          (response['lines'] as List).length > 1000) {
        throw const RegionDetectionException();
      }
      final lines = <List<AddressGlyph>>[];
      var count = 0;
      for (final line in response['lines'] as List) {
        if (line is! List) throw const RegionDetectionException();
        final glyphs = <AddressGlyph>[];
        for (final item in line) {
          if (++count > 30000 ||
              item is! Map ||
              item['text'] is! String ||
              (item['text'] as String).length > 100 ||
              item['box'] is! List) {
            throw const RegionDetectionException();
          }
          final box = item['box'] as List;
          if (box.length != 4 || box.any((v) => v is! num || !v.isFinite)) {
            throw const RegionDetectionException();
          }
          final r = Rect.fromLTRB(
            (box[0] as num).toDouble(),
            (box[1] as num).toDouble(),
            (box[2] as num).toDouble(),
            (box[3] as num).toDouble(),
          );
          if (r.left < 0 ||
              r.top < 0 ||
              r.right > pixels.width ||
              r.bottom > pixels.height ||
              r.isEmpty) {
            throw const RegionDetectionException();
          }
          glyphs.add(
            AddressGlyph(
              item['text'] as String,
              Rect.fromLTRB(
                r.left * photo.width / pixels.width,
                r.top * photo.height / pixels.height,
                r.right * photo.width / pixels.width,
                r.bottom * photo.height / pixels.height,
              ),
            ),
          );
        }
        lines.add(glyphs);
      }
      final phones = japanesePhoneNumberCandidates(
        [
          for (final line in lines)
            [for (final g in line) (text: g.text, bounds: g.bounds)],
        ],
        photo.width,
        photo.height,
      );
      return RegionDetection(
        candidates: [
          ...japaneseAddressCandidates(
            lines,
            photo.width,
            photo.height,
            dictionary: dictionary,
            mode: addressMode,
          ).where(
            (address) => !phones.any((phone) {
              final a = address.region.toRect();
              final p = phone.region.toRect();
              final overlap = a.intersect(p);
              final area = overlap.isEmpty
                  ? 0.0
                  : overlap.width * overlap.height;
              // An automatic number can contain a postal-code fragment.
              // An optional number replaces only a nearly identical box.
              return area >= a.width * a.height * .8 &&
                  (phone.automaticallySelected ||
                      area >= p.width * p.height * .8);
            }),
          ),
          ...phones,
        ],
        truncated: response['truncated'] == true || phones.length >= 100,
      );
    } catch (_) {
      throw const RegionDetectionException();
    } finally {
      _working = false;
    }
  }
}

class AddressGlyph {
  const AddressGlyph(this.text, this.bounds);
  final String text;
  final Rect bounds;
}

const _prefectures =
    '北海道|東京都|京都府|大阪府|青森県|岩手県|宮城県|秋田県|山形県|'
    '福島県|茨城県|栃木県|群馬県|埼玉県|千葉県|神奈川県|新潟県|富山県|石川県|'
    '福井県|山梨県|長野県|岐阜県|静岡県|愛知県|三重県|滋賀県|兵庫県|奈良県|'
    '和歌山県|鳥取県|島根県|岡山県|広島県|山口県|徳島県|香川県|愛媛県|高知県|'
    '福岡県|佐賀県|長崎県|熊本県|大分県|宮崎県|鹿児島県|沖縄県';
const _name = r'[一-龯々ヶケぁ-んァ-ヶー]';
const _number = r'[0-9一二三四五六七八九十百]+';
// Prefer a complete address where available; standalone components are added
// below without putting overlapping controls over that complete address.
final _address = RegExp(
  '(?:(?:$_prefectures)\\n?$_name{1,24}?[市区町村]\\n?|'
  '$_name{2,10}?[市区町村])'
  '$_name{1,30}?\\n?$_number'
  '(?:(?:丁目|番地?|号|条[東西南北]?|線|の|-)$_number)*(?:丁目|番地?|号)?'
  '(?:\\n?(?:$_name|[A-Za-z0-9]){1,30}?(?:ビル|マンション|ハイツ|タワー|荘|館)'
  '(?:$_number(?:号室|階|F)?)?)?',
);
final _prefecture = RegExp(_prefectures);
final _label = RegExp(r'^(?:住所|所在地|送付先|宛先)');
final _nonAddressUnit = RegExp(r'^(?:万人|億人|人|年|月|日|時|分|円|件|%)');
final _municipality = RegExp('$_name{1,20}[市区町村]');
final _componentLabel = RegExp(r'^(?:住所|所在地|市区町村|市町村|番地|地番)[:：]?');
final _lot = RegExp(
  '^(?:$_number(?:丁目|番地?|号)(?:(?:の|-)?$_number(?:番地?|号)?)*|'
  '[0-9]{1,4}(?:-[0-9]{1,4}){1,2})\$',
);
final _explicitLot = RegExp(
  '$_number(?:丁目|番地?|号)(?:(?:の|-)?$_number(?:番地?|号)?)*|'
  '[0-9]{1,4}(?:-[0-9]{1,4}){1,2}',
);
final _labelledLot = RegExp('^$_number\$');
// Aza/oaza/koaza components may appear without a municipality or lot number.
// Match a complete field, so ordinary words such as 文字 and 数字 do not match.
final _aza = RegExp(
  '^(?:大字|小字|字)(?![のをがはにでと])$_name{1,30}'
  '(?:$_number(?:(?:丁目|番地?|号|の|-)$_number)*(?:丁目|番地?|号)?)?\$',
);
final _postcode = RegExp(r'^[0-9]{3}-[0-9]{4}$');
// Do not extract seven digits from a longer phone number or identifier.
final _postalMention = RegExp(
  r'(?<![0-9A-Za-z-])〒?[0-9]{3}-?[0-9]{4}(?![0-9A-Za-z-])',
);
final _numericDate = RegExp(r'^(?:19|20)[0-9]{2}-[0-9]{1,2}-[0-9]{1,2}$');

typedef _AddressSpan = ({int start, int end});

// A second, recall-oriented pass finds mentions outside address fields. Keep
// hiragana prose boundaries instead of requiring a complete address or line.
const _mentionKanji = r'[一-龯々ヶケァ-ヶー]';
final _placeMention = RegExp(
  '(?:[ぁ-ん]{0,8}$_mentionKanji{1,20}?|[ぁ-ん]{1,8}?)[市区郡町村]',
);
final _azaMention = RegExp('(?:大字|小字|字)(?:$_mentionKanji{1,30}|[ぁ-ん]{1,12})');
final _mentionLabel = RegExp(r'^(?:住所|所在地|訪問先|開催地|出身地|配送先|対象地域|地名|字名)');
final _prosePrefix = RegExp(
  '^(?:にある|から|まで|では|には|の|は|が|を|へ|に|で|と|や)(?=$_mentionKanji)',
);
final _azaContext = RegExp(r'周辺|付近|方面|地区|案内|地図|入口|出口');
final _azaProse = RegExp(r'周辺|付近|方面|地区|案内|地図|入口|出口|への|からの|について|にある');
const _notPlaceNames = {'市町村', '市区町村', '市町', '市区', '町村', '田村', '中村', '木村'};

List<_AddressSpan> _mentions(String text) {
  final result = <_AddressSpan>[];
  for (final match in _placeMention.allMatches(text)) {
    var start = match.start;
    var end = match.end;
    if (end < text.length && RegExp(r'[市区町村]').hasMatch(text[end])) end++;
    final label = _mentionLabel.firstMatch(text.substring(start, end));
    start += label?.end ?? 0;
    start += _prosePrefix.firstMatch(text.substring(start, end))?.end ?? 0;
    final value = text.substring(start, end);
    if (value.length < 2 || _notPlaceNames.contains(value)) continue;
    result.add((start: start, end: end));
  }
  for (final match in _azaMention.allMatches(text)) {
    if (match.group(0)!.startsWith('字') &&
        match.start > 0 &&
        '文数漢活誤脱赤黒太斜習'.contains(text[match.start - 1])) {
      continue;
    }
    var end = match.end;
    final context = _azaContext.firstMatch(match.group(0)!);
    if (context != null) end = match.start + context.start;
    final value = text.substring(match.start, end);
    if ({'字', '大字', '小字', '字名', '大字名', '小字名'}.contains(value) ||
        RegExp(r'^(?:大字|小字|字)[のをがはにでと]').hasMatch(value)) {
      continue;
    }
    result.add((start: match.start, end: end));
  }
  return result;
}

// Parsing uses textual boundaries; coordinates always come from OCR glyphs.
final _city = RegExp('^$_name{1,20}?市');
final _ward = RegExp('^$_name{1,20}?区');
final _county = RegExp('^$_name{1,20}?郡');
final _townVillage = RegExp('^$_name{1,20}?[町村]');
final _azaMarker = RegExp(r'大字|小字|字');
final _numberStart = RegExp('[0-9]|[一二三四五六七八九十百]+(?=丁目|番地?|号|条)');
final _lotPrefix = RegExp(
  '^$_number(?:(?:丁目|番地?|号|条[東西南北]?|線|の|-)$_number)*(?:丁目|番地?|号)?',
);
final _otherField = RegExp(
  r'電話|携帯|氏名|名前|宛名|郵便番号|TEL|FAX|E-?mail',
  caseSensitive: false,
);

/// Empty means that a whole field cannot safely be treated as an address.
List<_AddressSpan> _components(String value, {bool continuation = false}) {
  final parts = <_AddressSpan>[];
  var cursor = 0;
  void take(int length) {
    parts.add((start: cursor, end: cursor + length));
    cursor += length;
  }

  bool consume(RegExp pattern) {
    final match = pattern.matchAsPrefix(value.substring(cursor));
    if (match == null) return false;
    var length = match.end;
    // 四日市市 and similar names contain the administrative suffix twice.
    if (cursor + length < value.length &&
        value[cursor + length] == value[cursor + length - 1]) {
      length++;
    }
    take(length);
    return true;
  }

  consume(_prefecture);
  final city = consume(_city);
  final ward = consume(_ward);
  final county = !city && !ward && consume(_county);
  final town = !city && !ward && consume(_townVillage);
  final hasLocality = city || ward || county || town;
  if (cursor == value.length) return parts;
  final rest = value.substring(cursor);
  final number = _numberStart.firstMatch(rest);
  final nameEnd = number?.start ?? rest.length;
  final name = rest.substring(0, nameEnd);
  final aza = _azaMarker.firstMatch(name);
  if (!hasLocality && !continuation && aza?.start != 0 && name.isNotEmpty) {
    return [];
  }
  if (number == null && name.isNotEmpty && aza == null && !name.endsWith('町')) {
    return [];
  }
  if (name.isNotEmpty) {
    if (aza != null && aza.start > 0) take(aza.start);
    if (aza != null) {
      final starts = _azaMarker.allMatches(name).map((m) => m.start).toList();
      for (var i = 0; i < starts.length; i++) {
        take((i + 1 < starts.length ? starts[i + 1] : name.length) - starts[i]);
      }
    } else {
      take(name.length);
    }
  }
  if (cursor < value.length) {
    final lot = _lotPrefix.matchAsPrefix(value.substring(cursor));
    if (lot == null ||
        _nonAddressUnit.hasMatch(value.substring(cursor + lot.end))) {
      return [];
    }
    if (!hasLocality &&
        !continuation &&
        name.isEmpty &&
        !RegExp(r'丁目|番|号|-').hasMatch(lot.group(0)!)) {
      return [];
    }
    if (!consume(_lotPrefix)) return [];
    if (cursor < value.length) take(value.length - cursor);
  }
  return parts;
}

// Examine consecutive OCR fields in reading order. Unrelated text or a layout
// break ends the run, even if another place name is nearby.
enum _FieldKind { address, label, aza, place, locality, lot, number }

typedef _AddressField = ({
  _FieldKind kind,
  _AddressSpan span,
  Rect bounds,
  int line,
});

final _addressFieldLabel = RegExp(r'^(?:住所|所在地|送付先|字名|番地|地番):?');
final _nextFieldLabel = RegExp(
  r'^(?:備考|電話|携帯|氏名|名前|宛名|TEL|FAX|E-?mail|管理番号|金額|価格)',
  caseSensitive: false,
);
final _lotProse = RegExp(r'^[でにはへを.。、,・(（]');
final _bareLot = RegExp(r'^[0-9]{1,5}$');

// A prefecture, a municipality and a locality may arrive as one OCR field.
// Validate the entire field so a sentence starting with a prefecture is not
// treated as a place name.
bool _isCompoundLocality(String value, PlaceNameDictionary? dictionary) {
  final prefecture = _prefecture.matchAsPrefix(value);
  if (prefecture == null) return false;
  final local = value.substring(prefecture.end);
  final municipality =
      _city.matchAsPrefix(local) ??
      _ward.matchAsPrefix(local) ??
      _townVillage.matchAsPrefix(local);
  if (municipality == null) return false;
  final town = local.substring(municipality.end);
  return town.isNotEmpty &&
      (dictionary?.contains(town) == true ||
          (_aza.hasMatch(town) &&
              !_azaProse.hasMatch(town) &&
              !RegExp(r'[ぁ-ん]').hasMatch(town)));
}

List<_AddressSpan> _nearbyAddressParts(
  String text,
  List<({int line, Rect rect})?> positions,
  Set<int> breaks,
  List<_AddressSpan> addresses,
  PlaceNameDictionary? dictionary,
) {
  final found = <_AddressSpan>{};
  final localities = <_AddressField>[];
  final leadingLots = <_AddressField>[];
  final run = <_AddressField>[];
  void finish() {
    // A standalone name and number are insufficient without a more specific
    // clue (an explicit aza, formatted lot, address label or known address).
    final selected = <int>{};
    for (var i = 0; i < run.length; i++) {
      final kind = run[i].kind;
      if (kind == _FieldKind.address || kind == _FieldKind.label) {
        // At most two neighboring fields per side (e.g. name and lot).
        selected.addAll([i - 2, i - 1, i + 1, i + 2]);
      }
      if (i == 0) continue;
      final previous = run[i - 1].kind;
      if ((previous == _FieldKind.aza &&
              (kind == _FieldKind.number || kind == _FieldKind.lot)) ||
          ((previous == _FieldKind.place || previous == _FieldKind.locality) &&
              kind == _FieldKind.lot)) {
        selected.addAll([i - 1, i]);
      }
    }
    for (final i in selected) {
      if (i < 0 || i >= run.length) continue;
      final field = run[i];
      if (field.kind != _FieldKind.address && field.kind != _FieldKind.label) {
        found.add(field.span);
      }
    }
    run.clear();
  }

  void append(_FieldKind kind, int start, int end) {
    var bounds = positions[start]!.rect;
    for (var i = start + 1; i < end; i++) {
      bounds = bounds.expandToInclude(positions[i]!.rect);
    }
    final line = positions[start]!.line;
    if (run.isNotEmpty) {
      final prev = run.last;
      final h = prev.bounds.height;
      final sameRow = (prev.bounds.center.dy - bounds.center.dy).abs() < h / 2;
      final close = sameRow
          ? bounds.left >= prev.bounds.left &&
                bounds.left - prev.bounds.right <= h * 1.5
          : line == prev.line + 1 &&
                bounds.top >= prev.bounds.top &&
                bounds.top - prev.bounds.bottom <= h &&
                bounds.left < prev.bounds.right &&
                bounds.right > prev.bounds.left;
      if (!close) finish();
    }
    final field = (
      kind: kind,
      span: (start: start, end: end),
      bounds: bounds,
      line: line,
    );
    run.add(field);
    if (kind == _FieldKind.locality) localities.add(field);
    if (kind == _FieldKind.lot &&
        (start == 0 || positions[start - 1]?.line != line)) {
      leadingLots.add(field);
    }
  }

  final covered = List<bool>.filled(text.length, false);
  for (final span in addresses) {
    covered.fillRange(span.start, span.end, true);
  }
  var blockedLine = -1;
  var start = 0;
  while (start < text.length) {
    if (positions[start] == null) {
      start++;
      continue;
    }
    var end = start + 1;
    while (end < text.length &&
        positions[end] != null &&
        !breaks.contains(end) &&
        covered[end] == covered[start]) {
      end++;
    }
    if (covered[start]) {
      append(_FieldKind.address, start, end);
    } else {
      var value = text.substring(start, end);
      final line = positions[start]!.line;
      if (_nextFieldLabel.hasMatch(value)) {
        finish();
        blockedLine = line;
      }
      final label = _addressFieldLabel.matchAsPrefix(value);
      if (line == blockedLine && label == null) {
        start = end;
        continue;
      }
      if (label != null) {
        finish();
        blockedLine = -1;
        append(_FieldKind.label, start, start + label.end);
        start += label.end;
        value = value.substring(label.end);
      }
      if (value.isNotEmpty) {
        final lot = _explicitLot.matchAsPrefix(value);
        if (lot != null &&
            !_numericDate.hasMatch(value) &&
            (lot.end == value.length ||
                _lotProse.hasMatch(value.substring(lot.end)))) {
          append(_FieldKind.lot, start, start + lot.end);
          if (lot.end != value.length) finish();
        } else if (_bareLot.hasMatch(value)) {
          append(_FieldKind.number, start, end);
        } else if (_aza.hasMatch(value) &&
            !_azaProse.hasMatch(value) &&
            !RegExp(
              r'[へでにをがは]',
            ).hasMatch(value.substring(_azaMarker.matchAsPrefix(value)!.end))) {
          append(_FieldKind.aza, start, end);
        } else if (_isCompoundLocality(value, dictionary)) {
          append(_FieldKind.locality, start, end);
        } else if (dictionary?.contains(value) == true) {
          append(_FieldKind.place, start, end);
        } else {
          finish();
        }
      }
    }
    start = end;
  }
  finish();
  // Vision can emit a wrapped lot before its locality, with unrelated OCR
  // observations in between. Resolve only an unambiguous next-row match.
  for (final locality in localities) {
    final upper = locality.bounds;
    final matches = leadingLots.where((lot) {
      final lower = lot.bounds;
      final drop = lower.center.dy - upper.center.dy;
      return lower.right <= upper.left &&
          drop >= upper.height * .5 &&
          drop <= upper.height * 2 &&
          lower.height >= upper.height * .5 &&
          lower.height <= upper.height * 2;
    });
    if (matches.length == 1) {
      found.add(locality.span);
      found.add(matches.first.span);
    }
  }
  return found.toList();
}

String _normalize(String value) => String.fromCharCodes(
  value.runes.map((r) => r >= 0xFF01 && r <= 0xFF5E ? r - 0xFEE0 : r),
).replaceAll(RegExp(r'[ \t\u3000]'), '').replaceAll(RegExp('[‐‑‒–—―−]'), '-');

/// OCR bounds, not estimated character widths, define the masks. A match is
/// split by physical line so a wrapped address never masks the space between.
List<RegionCandidate> japaneseAddressCandidates(
  List<List<AddressGlyph>> lines,
  int width,
  int height, {
  PlaceNameDictionary? dictionary,
  AddressDetectionMode mode = AddressDetectionMode.placeNames,
}) {
  if (mode == AddressDetectionMode.off) return [];
  final text = StringBuffer();
  final positions = <({int line, Rect rect})?>[];
  final componentBreaks = <int>{};
  for (var i = 0; i < lines.length; i++) {
    Rect? previous;
    for (final glyph in lines[i]) {
      final normalized = _normalize(glyph.text);
      if (normalized.isEmpty ||
          (previous != null &&
              glyph.bounds.left - previous.right > previous.height * .75)) {
        componentBreaks.add(positions.length);
      }
      previous = glyph.bounds;
      text.write(normalized);
      positions.addAll(
        List.filled(normalized.length, (line: i, rect: glyph.bounds)),
      );
    }
    text.write('\n');
    positions.add(null);
  }
  final spans = <_AddressSpan>[];
  final normalizedText = text.toString().replaceAll(
    RegExp('[ーｰ](?=[0-9])'),
    '-',
  );
  bool crossesColumn(int start, int end) {
    for (var i = start + 1; i < end; i++) {
      if (!componentBreaks.contains(i)) continue;
      final before = positions[i - 1];
      final after = positions[i];
      if (before != null &&
          after != null &&
          after.rect.left - before.rect.right > before.rect.height * 1.5) {
        return true;
      }
    }
    return false;
  }

  for (final match in _address.allMatches(normalizedText)) {
    if (_nonAddressUnit.hasMatch(normalizedText.substring(match.end))) continue;
    final value = match.group(0)!;
    // A generic city/ward match must not consume a preceding address label or
    // recipient when an exact prefecture name gives us a better start offset.
    final prefecture = _prefecture.firstMatch(value);
    final start =
        match.start + (prefecture?.start ?? _label.firstMatch(value)?.end ?? 0);
    final bounds = <int, Rect>{};
    for (var i = start; i < match.end; i++) {
      final p = positions[i];
      if (p != null) {
        bounds[p.line] = bounds[p.line]?.expandToInclude(p.rect) ?? p.rect;
      }
    }
    // Join only adjacent lines of the same address, never unrelated columns.
    final boxes = bounds.values.toList();
    if (boxes.length > 1 &&
        boxes.asMap().entries.skip(1).any((e) {
          final before = boxes[e.key - 1];
          final after = e.value;
          return after.top < before.top ||
              after.top - before.bottom > before.height * 2 ||
              after.left > before.right ||
              after.right < before.left;
        })) {
      continue;
    }
    if (mode == AddressDetectionMode.addressOnly) {
      if (crossesColumn(start, match.end)) continue;
      spans.add((start: start, end: match.end));
      continue;
    }
    var end = match.end;
    // Include any contiguous trailing building/room text, not just a list of
    // building suffixes. Explicit other-field labels and OCR gaps stop it.
    final newline = normalizedText.indexOf('\n', end);
    var limit = newline < 0 ? normalizedText.length : newline;
    for (final cut in componentBreaks) {
      if (cut >= end && cut < limit) limit = cut;
    }
    final other = _otherField.firstMatch(normalizedText.substring(end, limit));
    if (other != null) limit = end + other.start;
    final punctuation = RegExp(r'[,、:：;；]')
        .firstMatch(normalizedText.substring(end, limit));
    if (punctuation != null) limit = end + punctuation.start;
    final suffix = normalizedText.substring(end, limit);
    if (!suffix.endsWith('様') && !suffix.endsWith('御中')) end = limit;
    spans.add((start: start, end: end));
  }

  final postalSpans = [
    for (final match in _postalMention.allMatches(normalizedText))
      (start: match.start, end: match.end),
  ];
  if (mode == AddressDetectionMode.addressOnly) {
    // Also recognize abbreviated addresses such as 神南1-2-3.
    for (final place
        in dictionary?.matches(normalizedText) ?? <_AddressSpan>[]) {
      final lot = _explicitLot.matchAsPrefix(normalizedText, place.end);
      if (lot == null ||
          crossesColumn(place.start, lot.end) ||
          spans.any((s) => place.start < s.end && lot.end > s.start)) {
        continue;
      }
      spans.add((start: place.start, end: lot.end));
    }
    return _addressRegions(
      _mergeSpans([
        ...spans,
        ..._nearbyAddressParts(normalizedText, positions, componentBreaks, [
          ...spans,
          ...postalSpans,
        ], dictionary),
      ], postalSpans),
      positions,
      width,
      height,
    );
  }

  bool overlaps(int start, int end) =>
      spans.any((span) => start < span.end && end > span.start);

  // Prefectures have an exact vocabulary, so they can also be found in prose.
  for (final match in _prefecture.allMatches(normalizedText)) {
    if (!overlaps(match.start, match.end)) {
      spans.add((start: match.start, end: match.end));
    }
  }

  var offset = 0;
  for (final line in normalizedText.split('\n')) {
    // Mask already recognized spans with separators, preserving OCR offsets.
    final remaining = List.generate(
      line.length,
      (i) => overlaps(offset + i, offset + i + 1) ? ' ' : line[i],
    ).join();
    final lineLabel = _componentLabel.firstMatch(remaining);
    final cuts = {
      0,
      line.length,
      for (final cut in componentBreaks)
        if (cut > offset && cut < offset + line.length) cut - offset,
    }.toList()..sort();
    final segments = [
      for (var i = 0; i + 1 < cuts.length; i++)
        for (final match in RegExp(
          r'[^ ,、:：;；/／]+',
        ).allMatches(remaining.substring(cuts[i], cuts[i + 1])))
          (start: cuts[i] + match.start, value: match.group(0)!),
    ];
    for (final segment in segments) {
      final label = _componentLabel.firstMatch(segment.value);
      final value = segment.value.substring(label?.end ?? 0);
      final start = offset + segment.start + (label?.end ?? 0);
      // Let the mention pass isolate the name rather than hiding prose as
      // though it were a standalone aza field.
      if (_azaMarker.matchAsPrefix(value) != null &&
          _azaProse.hasMatch(value) &&
          !_numberStart.hasMatch(value)) {
        continue;
      }
      final composed = _components(value);
      if (composed.length > 1 &&
          !_otherField.hasMatch(value) &&
          !value.endsWith('様') &&
          !value.endsWith('御中') &&
          !_numericDate.hasMatch(value) &&
          !_postcode.hasMatch(value) &&
          !value.startsWith('0')) {
        for (final part in composed) {
          spans.add((start: start + part.start, end: start + part.end));
        }
        continue;
      }
      if (_aza.hasMatch(value) && !{'字名', '大字名', '小字名'}.contains(value)) {
        spans.add((start: start, end: start + value.length));
        continue;
      }
      // Accept isolated municipality names (including city + ward), not any
      // sentence containing 市/町/村 or surnames such as 田村 and 中村.
      final municipalities = _municipality.allMatches(value).toList();
      if (municipalities.isNotEmpty &&
          municipalities.first.start == 0 &&
          municipalities.last.end == value.length &&
          municipalities.map((m) => m.group(0)).join() == value &&
          !{
            '市区町村',
            '市町村',
            '田村',
            '中村',
            '木村',
            '村',
            '町',
            '市',
            '区',
          }.contains(value)) {
        for (final m in municipalities) {
          spans.add((start: start + m.start, end: start + m.end));
        }
        continue;
      }
      final labelled = [label, lineLabel].any(
        (m) =>
            m != null &&
            (m.group(0)!.startsWith('番地') || m.group(0)!.startsWith('地番')),
      );
      if ((_lot.hasMatch(value) ||
              (labelled && _labelledLot.hasMatch(value))) &&
          !_postcode.hasMatch(value) &&
          !_numericDate.hasMatch(value) &&
          !value.startsWith('0')) {
        spans.add((start: start, end: start + value.length));
      }
    }
    offset += line.length + 1;
  }

  // Cover place-name mentions in prose/headings as well as complete fields.
  final mentionText = List.generate(
    normalizedText.length,
    (i) => overlaps(i, i + 1) ? ' ' : normalizedText[i],
  ).join();
  for (final mention in _mentions(mentionText)) {
    if (!overlaps(mention.start, mention.end)) spans.add(mention);
  }

  final splitSpans = <_AddressSpan>[];
  for (final span in spans) {
    // Split each physical line independently; no frame bridges a line break.
    var start = span.start;
    for (final line
        in normalizedText.substring(span.start, span.end).split('\n')) {
      final parts = _components(line, continuation: true);
      if (parts.isEmpty) {
        if (line.isNotEmpty) {
          splitSpans.add((start: start, end: start + line.length));
        }
      } else {
        for (final part in parts) {
          splitSpans.add((start: start + part.start, end: start + part.end));
        }
      }
      start += line.length + 1;
    }
  }
  // Once a place name is identified, hide every other occurrence in this
  // photo too. An explicit 字北山 also identifies bare 北山 elsewhere.
  final names = <String>{};
  for (final span in splitSpans) {
    final value = normalizedText.substring(span.start, span.end);
    if (_prefecture.hasMatch(value) ||
        _municipality.hasMatch(value) ||
        _azaMarker.matchAsPrefix(value) != null) {
      names.add(value);
      final marker = _azaMarker.matchAsPrefix(value);
      if (marker != null && value.length - marker.end >= 2) {
        names.add(value.substring(marker.end));
      }
    }
  }
  for (final name in names) {
    var from = 0;
    while (from < normalizedText.length) {
      final at = normalizedText.indexOf(name, from);
      if (at < 0) break;
      final end = at + name.length;
      if (!splitSpans.any((s) => at < s.end && end > s.start)) {
        splitSpans.add((start: at, end: end));
      }
      from = end;
    }
  }
  splitSpans.sort((a, b) => a.start.compareTo(b.start));
  // Dictionary boundaries take priority. Keep the uncovered parts of existing
  // masks (lot numbers and trailing text) without overlapping place controls.
  // A known lot and its trailing label remain whole controls, even if a
  // short registered name occurs inside them (e.g. 棟 in ABC棟).
  final protectedSpans = <_AddressSpan>[];
  for (var i = 0; i < splitSpans.length; i++) {
    final span = splitSpans[i];
    if (_lot.hasMatch(normalizedText.substring(span.start, span.end))) {
      protectedSpans.add(span);
      if (i + 1 < splitSpans.length && splitSpans[i + 1].start == span.end) {
        protectedSpans.add(splitSpans[i + 1]);
      }
    }
  }
  final protectedControls = [...protectedSpans, ...postalSpans];
  final dictionarySpans =
      dictionary
          ?.matches(normalizedText)
          .where(
            (match) => !protectedControls.any(
              (span) => match.start < span.end && match.end > span.start,
            ),
          )
          .toList() ??
      <_AddressSpan>[];
  // Keep the postal code as one independent control, including 〒 if present.
  dictionarySpans.addAll(postalSpans);
  return _addressRegions(
    _mergeSpans(splitSpans, dictionarySpans),
    positions,
    width,
    height,
  );
}

// Keep postal and dictionary matches whole when they overlap an address.
List<_AddressSpan> _mergeSpans(
  List<_AddressSpan> spans,
  List<_AddressSpan> prioritySpans,
) {
  prioritySpans.sort((a, b) => a.start.compareTo(b.start));
  final finalSpans = <_AddressSpan>[...prioritySpans];
  for (final span in spans) {
    var low = 0;
    var high = prioritySpans.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (prioritySpans[middle].end <= span.start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    var cursor = span.start;
    for (
      var i = low;
      i < prioritySpans.length && prioritySpans[i].start < span.end;
      i++
    ) {
      final match = prioritySpans[i];
      if (cursor < match.start) {
        finalSpans.add((start: cursor, end: match.start));
      }
      if (match.end > cursor) cursor = match.end;
    }
    if (cursor < span.end) finalSpans.add((start: cursor, end: span.end));
  }
  finalSpans.sort((a, b) => a.start.compareTo(b.start));
  return finalSpans;
}

List<RegionCandidate> _addressRegions(
  List<_AddressSpan> spans,
  List<({int line, Rect rect})?> positions,
  int width,
  int height,
) {
  final regions = <HideRegion>{};
  for (final span in spans) {
    final bounds = <int, Rect>{};
    for (var i = span.start; i < span.end; i++) {
      final p = positions[i];
      if (p != null) {
        bounds[p.line] = bounds[p.line]?.expandToInclude(p.rect) ?? p.rect;
      }
    }
    for (final rect in bounds.values) {
      final region = HideRegion.fromRect(
        rect.inflate(2),
        imageWidth: width,
        imageHeight: height,
      );
      if (region != null) regions.add(region);
    }
  }
  return [
    for (final region in regions)
      RegionCandidate(kind: CandidateKind.address, region: region),
  ];
}
