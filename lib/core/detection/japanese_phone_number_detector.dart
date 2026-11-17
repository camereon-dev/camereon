import 'dart:math' as math;
import 'dart:ui';

import '../photo/hide_region.dart';
import 'region_detector.dart';

/// The existing OCR supplies these glyphs; no extra native OCR call is made.
typedef PhoneGlyph = ({String text, Rect bounds});

/// Short, labelled local numbers are offered without being hidden by default.
class PhoneNumberCandidate extends RegionCandidate {
  const PhoneNumberCandidate({
    required super.region,
    required this.automaticallySelected,
  }) : super(kind: CandidateKind.phone);

  final bool automaticallySelected;
}

final _numbers = RegExp(r'(?:\+[0-9]|\([0-9]|[0-9])(?:[0-9 ()-]*[0-9])?');
const _phoneLabels = r'電話番号|携帯電話|携帯番号|電話|携帯|TEL(?:EPHONE)?|PHONE|連絡先';
final _phoneLabel = RegExp(
  '(?:$_phoneLabels)(?:は)?[ :：.]*\$',
  caseSensitive: false,
);
final _labelOnly = RegExp(
  '^[ ]*(?:$_phoneLabels)[ :：.]*\$',
  caseSensitive: false,
);
final _otherLabel = RegExp(
  r'(?:管理番号|注文番号|伝票番号|受付番号|会員番号|商品番号|商品コード|'
  r'口座番号|顧客番号|追跡番号|郵便番号|ID|FAX)[ :：.#-]*$',
  caseSensitive: false,
);
final _word = RegExp(r'[0-9A-Za-z+@\-]');
final _date = RegExp(r'^(?:19|20)[0-9]{2}-?[0-9]{2}-?[0-9]{2}$');

String _normalize(String text) => String.fromCharCodes([
  for (final unit in text.codeUnits)
    if (unit >= 0xff01 && unit <= 0xff5e)
      unit - 0xfee0
    else if ('‐‑‒–—―−﹣ー'.codeUnits.contains(unit))
      0x2d
    else if (unit == 0x3000 || unit == 0xa0)
      0x20
    else
      unit,
]);

({String text, List<Rect?> positions, Rect bounds}) _line(
  List<PhoneGlyph> glyphs,
) {
  final text = StringBuffer();
  final positions = <Rect?>[];
  Rect? previous;
  Rect? bounds;
  for (final glyph in glyphs) {
    final r = glyph.bounds;
    if (r.isEmpty || !r.isFinite) continue;
    bounds = bounds == null ? r : bounds.expandToInclude(r);
    if (previous != null &&
        r.left - previous.right >
            math.max(24, math.max(r.height, previous.height) * 1.5)) {
      // A separate column must not become part of this phone number or label.
      text.write('\t');
      positions.add(null);
    }
    final value = _normalize(glyph.text);
    text.write(value);
    positions.addAll(List<Rect?>.filled(value.length, r));
    previous = r;
  }
  return (
    text: text.toString(),
    positions: positions,
    bounds: bounds ?? Rect.zero,
  );
}

String? _nationalNumber(String raw) {
  var value = raw.replaceAll(' ', '');
  if (value.startsWith('+81')) {
    value = value.substring(3);
    if (value.startsWith('-')) value = value.substring(1);
    if (value.startsWith('(0)')) value = value.substring(3);
    if (value.startsWith('-')) value = value.substring(1);
    if (value.startsWith('0')) return null;
    value = '0$value';
  } else if (value.startsWith('+')) {
    return null;
  }
  if ('('.allMatches(value).length != ')'.allMatches(value).length) return null;
  if (value.contains('(') &&
      !RegExp(r'^\([0-9]{2,5}\)[0-9-]+$').hasMatch(value)) {
    return null;
  }
  final digits = value.replaceAll(RegExp(r'[()\-]'), '');
  if (!RegExp(r'^[0-9]+$').hasMatch(digits)) return null;
  // Reject malformed hyphen groups, but tolerate spaces inserted by OCR.
  final groups = value.replaceAll(RegExp(r'[()]'), '').split('-');
  if (groups.any((g) => g.isEmpty) || groups.length > 3) return null;
  if (groups.length > 1 && groups.last.length != 4) {
    if (!(digits.startsWith('0120') || digits.startsWith('0570')) ||
        groups.last.length != 3) {
      return null;
    }
  }
  return digits;
}

bool _completeJapaneseNumber(String number) {
  if (RegExp(r'^0(?:50|60|70|80|90)[0-9]{8}$').hasMatch(number)) return true;
  // 10-digit geographic/service formats. Allocation and reachability are not
  // checked. 050/070/080/090 etc. must not accidentally match as 10 digits.
  return RegExp(r'^0[1-9][0-9]{8}$').hasMatch(number) &&
      !RegExp(r'^0(?:10|20|50|70|80|90)').hasMatch(number);
}

/// Japanese full numbers are automatically selected. Label-supported local
/// numbers (7/8 digits) remain optional. OCR text is never retained in results.
List<PhoneNumberCandidate> japanesePhoneNumberCandidates(
  List<List<PhoneGlyph>> lines,
  int imageWidth,
  int imageHeight,
) {
  final result = <PhoneNumberCandidate>[];
  final prepared = lines.map(_line).toList();
  for (var lineIndex = 0; lineIndex < prepared.length; lineIndex++) {
    final line = prepared[lineIndex];
    for (final match in _numbers.allMatches(line.text)) {
      final prefix = line.text.substring(0, match.start);
      final sameLineLabel = _phoneLabel.hasMatch(prefix.split('\t').last);
      if (_otherLabel.hasMatch(prefix.split('\t').last)) continue;
      if (match.start > 0 &&
          _word.hasMatch(line.text[match.start - 1]) &&
          !sameLineLabel) {
        continue;
      }
      if (match.end < line.text.length &&
          _word.hasMatch(line.text[match.end])) {
        continue;
      }
      final number = _nationalNumber(match.group(0)!);
      if (number == null) continue;
      Rect? box;
      for (final position in line.positions.sublist(match.start, match.end)) {
        if (position != null) {
          box = box == null ? position : box.expandToInclude(position);
        }
      }
      if (box == null) continue;
      var labelled = sameLineLabel;
      if (!labelled && lineIndex > 0) {
        final previous = prepared[lineIndex - 1];
        final gap = box.top - previous.bounds.bottom;
        labelled =
            _labelOnly.hasMatch(previous.text) &&
            gap >= -2 &&
            gap <= previous.bounds.height * 2 &&
            (box.left - previous.bounds.left).abs() <=
                math.max(24, previous.bounds.height * 2);
      }
      final complete = _completeJapaneseNumber(number);
      final local =
          labelled &&
          !match.group(0)!.startsWith('+') &&
          RegExp(r'^[1-9][0-9]{6,7}$').hasMatch(number) &&
          !_date.hasMatch(match.group(0)!.replaceAll(' ', ''));
      if (!complete && !local) continue;
      final region = HideRegion.fromRect(
        box.inflate(math.max(2, box.height * .15)),
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
      if (region == null || result.any((c) => c.region == region)) continue;
      result.add(
        PhoneNumberCandidate(region: region, automaticallySelected: complete),
      );
      if (result.length == 100) return result;
    }
  }
  return result;
}
