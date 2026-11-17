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

String? _numberDigits(String raw) {
  final digits = raw.replaceAll(RegExp(r'[+ ()\-]'), '');
  return RegExp(r'^[0-9]+$').hasMatch(digits) ? digits : null;
}

bool _automaticallyMaskNumber(String number) {
  // Prefer recall over exact telephone-format validation, including IDs.
  if (number.length >= 9) return true;
  return RegExp(r'^0(?:50|60|70|80|90)[0-9]{4,5}$').hasMatch(number);
}

/// Nine or more digits, or 7/8 digits starting with a mobile/IP prefix, are
/// automatically selected. Other labelled local numbers remain optional.
/// OCR text is never retained in results.
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
      if (match.start > 0 &&
          _word.hasMatch(line.text[match.start - 1]) &&
          !sameLineLabel) {
        continue;
      }
      if (match.end < line.text.length &&
          _word.hasMatch(line.text[match.end])) {
        continue;
      }
      final number = _numberDigits(match.group(0)!);
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
      final complete = _automaticallyMaskNumber(number);
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
