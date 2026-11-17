import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Immutable packed UTF-16 trie. No per-name objects or networking at runtime.
class PlaceNameDictionary {
  PlaceNameDictionary._(this._data, this._nodes, this.maxNameLength);
  final ByteData _data;
  final int _nodes;
  final int maxNameLength;
  static Future<PlaceNameDictionary>? _loading;
  static bool _licenseRegistered = false;

  static void registerLicense() {
    if (_licenseRegistered) return;
    _licenseRegistered = true;
    LicenseRegistry.addLicense(() async* {
      yield LicenseEntryWithLineBreaks([
        'camereon address dictionary',
      ], await rootBundle.loadString('assets/address_dictionary/NOTICE.txt'));
    });
  }

  static Future<PlaceNameDictionary> load() {
    registerLicense();
    return _loading ??= _load().catchError((Object error, StackTrace stack) {
      _loading = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  static Future<PlaceNameDictionary> _load() async {
    final asset = await rootBundle.load('assets/address_dictionary/names.bin');
    return compute(
      PlaceNameDictionary.fromBytes,
      asset.buffer.asUint8List(asset.offsetInBytes, asset.lengthInBytes),
    );
  }

  /// Validate the shipped format before using offsets from the asset.
  static PlaceNameDictionary fromBytes(Uint8List bytes) {
    if (bytes.length < 16 || String.fromCharCodes(bytes.take(4)) != 'JPN1') {
      throw const FormatException('Invalid place-name dictionary header');
    }
    final data = ByteData.sublistView(bytes);
    final nodes = data.getUint32(4, Endian.little);
    final edges = data.getUint32(8, Endian.little);
    final depth = data.getUint32(12, Endian.little);
    if (nodes < 1 ||
        nodes > 2000000 ||
        edges != nodes - 1 ||
        depth < 1 ||
        depth > 200 ||
        bytes.length != 16 + nodes * 8 + edges * 8) {
      throw const FormatException('Invalid place-name dictionary size');
    }
    var nextEdge = 0;
    for (var node = 0; node < nodes; node++) {
      final offset = 16 + node * 8;
      final first = data.getUint32(offset, Endian.little);
      final count = data.getUint16(offset + 4, Endian.little);
      if (first != nextEdge ||
          first + count > edges ||
          data.getUint16(offset + 6, Endian.little) > 15) {
        throw const FormatException('Invalid place-name dictionary node');
      }
      var previous = -1;
      for (var edge = first; edge < first + count; edge++) {
        final at = 16 + nodes * 8 + edge * 8;
        final unit = data.getUint32(at, Endian.little);
        final child = data.getUint32(at + 4, Endian.little);
        if (unit > 65535 ||
            unit <= previous ||
            child <= node ||
            child >= nodes) {
          throw const FormatException('Invalid place-name dictionary edge');
        }
        previous = unit;
      }
      nextEdge += count;
    }
    if (nextEdge != edges) {
      throw const FormatException('Unused dictionary edges');
    }
    return PlaceNameDictionary._(data, nodes, depth);
  }

  int? _child(int node, int unit) {
    final at = 16 + node * 8;
    var low = _data.getUint32(at, Endian.little);
    var high = low + _data.getUint16(at + 4, Endian.little) - 1;
    while (low <= high) {
      final mid = (low + high) >> 1;
      final edge = 16 + _nodes * 8 + mid * 8;
      final value = _data.getUint32(edge, Endian.little);
      if (value == unit) return _data.getUint32(edge + 4, Endian.little);
      if (value < unit) {
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    return null;
  }

  bool _terminal(int node) =>
      _data.getUint16(16 + node * 8 + 6, Endian.little) != 0;

  bool contains(String value) {
    var node = 0;
    for (final unit in value.codeUnits) {
      final child = _child(node, unit);
      if (child == null) return false;
      node = child;
    }
    return value.isNotEmpty && _terminal(node);
  }

  /// Longest name at each position, then continue after that name. This keeps
  /// 豊橋市 in one frame instead of overlapping 豊橋 and 豊橋市 controls.
  Iterable<({int start, int end})> matches(String text) sync* {
    var start = 0;
    while (start < text.length) {
      var node = 0;
      var end = start;
      for (
        var cursor = start;
        cursor < text.length && cursor - start < maxNameLength;
        cursor++
      ) {
        final child = _child(node, text.codeUnitAt(cursor));
        if (child == null) break;
        node = child;
        if (_terminal(node)) end = cursor + 1;
      }
      if (end > start) {
        yield (start: start, end: end);
        start = end;
      } else {
        start++;
      }
    }
  }
}
