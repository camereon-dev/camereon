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

final _numbers = RegExp(
  r'(?:\+[0-9Oo]|\([0-9Oo]|[0-9Oo])(?:[0-9Oo ()-]*[0-9Oo])?',
);
typedef _PhoneLine = ({String text, List<Rect?> positions, Rect bounds});
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
final _fixedLine = RegExp(r'^[0Oo][36][ -]+[0-9Oo]{4}[ -]+[0-9Oo]{4}$');
final _numberPunctuation = RegExp(r'^[ ()-]*$');

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

_PhoneLine _line(List<PhoneGlyph> glyphs) {
  final text = StringBuffer();
  final positions = <Rect?>[];
  Rect? previous;
  Rect? bounds;
  for (final glyph in glyphs) {
    final r = glyph.bounds;
    if (r.isEmpty || !r.isFinite) continue;
    bounds = bounds == null ? r : bounds.expandToInclude(r);
    if (previous != null) {
      final height = math.max(r.height, previous.height);
      final gap = r.left - previous.right;
      if (!_sameRow(previous, r) || gap > height) {
        text.write('\t');
        positions.add(null);
      } else if (gap > height * .25) {
        // Keep an OCR gap visible so fragment length checks can inspect it.
        text.write(' ');
        positions.add(null);
      }
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
  // Correct O/o only inside number-like runs, never in the source OCR text.
  if (!RegExp(r'[0-9]').hasMatch(raw)) return null;
  final digits = raw
      .replaceAll(RegExp(r'[Oo]'), '0')
      .replaceAll(RegExp(r'[+ ()\-]'), '');
  return RegExp(r'^[0-9]+$').hasMatch(digits) ? digits : null;
}

bool _sameRow(Rect a, Rect b) =>
    math.min(a.bottom, b.bottom) - math.max(a.top, b.top) >=
    math.min(a.height, b.height) * .5;

Rect? _rangeBounds(_PhoneLine line, int start, int end) {
  Rect? box;
  for (final position in line.positions.sublist(start, end)) {
    if (position != null) {
      box = box == null ? position : box.expandToInclude(position);
    }
  }
  return box;
}

bool _nearby(Rect a, Rect b) =>
    _sameRow(a, b) &&
    b.left >= a.right - 2 &&
    b.left - a.right <= math.max(a.height, b.height);

typedef _Fragment = ({String raw, String digits, Rect bounds});
typedef _JoinableLine = ({_PhoneLine line, _Fragment? head, _Fragment? tail});

_Fragment? _fragment(_PhoneLine line, RegExpMatch match) {
  final raw = match.group(0)!;
  final digits = _numberDigits(raw);
  final bounds = _rangeBounds(line, match.start, match.end);
  if (digits == null || bounds == null) return null;
  return (raw: raw, digits: digits, bounds: bounds);
}

_JoinableLine _joinable(_PhoneLine line) {
  final matches = _numbers.allMatches(line.text).toList();
  if (matches.isEmpty) return (line: line, head: null, tail: null);
  final first = matches.first;
  final last = matches.last;
  return (
    line: line,
    head:
        _numberPunctuation.hasMatch(line.text.substring(0, first.start)) &&
            line.text.substring(first.end).trim().isEmpty
        ? _fragment(line, first)
        : null,
    tail: _numberPunctuation.hasMatch(line.text.substring(last.end))
        ? _fragment(line, last)
        : null,
  );
}

_JoinableLine? _join(_JoinableLine left, _JoinableLine right) {
  final a = left.tail;
  final b = right.head;
  if (a == null || b == null || !_nearby(a.bounds, b.bounds)) return null;
  final international = a.raw.startsWith('+81');
  final fixedPrefix =
      (a.digits == '03' || a.digits == '06') &&
      (b.digits.length == 4 || _fixedLine.hasMatch('${a.raw} ${b.raw}'));
  if (!international &&
      !fixedPrefix &&
      (a.digits.length < 3 || b.digits.length < 3)) {
    return null;
  }
  return _joinable((
    text: '${left.line.text} ${right.line.text}',
    positions: [...left.line.positions, null, ...right.line.positions],
    bounds: left.line.bounds.expandToInclude(right.line.bounds),
  ));
}

// OCR may return parts of one printed row as separate observations. Cache the
// edge fragments so each nearby-line comparison avoids rescanning the text.
List<_PhoneLine> _joinNearbyLines(List<_PhoneLine> lines) {
  final edges = lines.map(_joinable).toList();
  final joined = <_PhoneLine>[];
  final consumed = <int>{};
  for (var i = 0; i < edges.length; i++) {
    if (consumed.contains(i)) continue;
    var current = edges[i];
    for (var j = i + 1; j < edges.length; j++) {
      if (consumed.contains(j)) continue;
      final other = edges[j];
      if (!_sameRow(current.line.bounds, other.line.bounds)) continue;
      final merged = _join(current, other) ?? _join(other, current);
      if (merged == null) continue;
      current = merged;
      consumed.add(j);
      // The merged observation may now reach an earlier, skipped neighbor.
      j = i;
    }
    joined.add(current.line);
  }
  return joined;
}

// Spaces only join nearby numeric chunks with at least three digits, or the
// short prefixes in +81 and 03/06 fixed-line notation. Tabs keep offsets.
String _numberText(_PhoneLine line) {
  final units = line.text.codeUnits.toList();
  final shortPrefixRuns = _numbers.allMatches(line.text).where((match) {
    final raw = match.group(0)!;
    return _fixedLine.hasMatch(raw) ||
        (raw.startsWith('+81') && (_numberDigits(raw)?.length ?? 0) >= 11);
  }).toList();
  for (final gap in RegExp(r' +').allMatches(line.text)) {
    final before = RegExp(r'[0-9Oo]+$')
        .firstMatch(line.text.substring(0, gap.start));
    final after = RegExp(r'^[0-9Oo]+').firstMatch(line.text.substring(gap.end));
    if (before == null || after == null) continue;
    final a = _rangeBounds(line, before.start, gap.start);
    final b = _rangeBounds(line, gap.end, gap.end + after.end);
    final shortPrefix = shortPrefixRuns.any(
      (run) => run.start <= gap.start && run.end >= gap.end,
    );
    if ((shortPrefix ||
            (before.group(0)!.length >= 3 && after.group(0)!.length >= 3)) &&
        a != null &&
        b != null &&
        _nearby(a, b)) {
      continue;
    }
    for (var i = gap.start; i < gap.end; i++) {
      units[i] = 9;
    }
  }
  return String.fromCharCodes(units);
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
  final prepared = _joinNearbyLines(lines.map(_line).toList());
  for (var lineIndex = 0; lineIndex < prepared.length; lineIndex++) {
    final line = prepared[lineIndex];
    for (final match in _numbers.allMatches(_numberText(line))) {
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
      final box = _rangeBounds(line, match.start, match.end);
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
      // A guessed O/o correction must satisfy an automatic masking rule.
      if (RegExp(r'[Oo]').hasMatch(match.group(0)!) && !complete) continue;
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
