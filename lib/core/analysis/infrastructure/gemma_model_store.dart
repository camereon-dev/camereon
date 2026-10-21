import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../scene_analysis.dart';

/// tools/vlm-eval/model.json と同じ検証済み配布物。変更時は両方を更新する。
abstract final class GemmaModelSpec {
  static const filename = 'gemma-4-E2B-it.litertlm';
  static const bytes = 2588147712;
  static const sha256Hex =
      '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c';
  static const revision = '41c5569623a7c189d6eec3e5225260c58cedbce7';
  static const url =
      'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/$revision/$filename';
  static const workingBytes = 2 * 1024 * 1024 * 1024;
}

Future<String> _checksum(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

// Capture only a path: the downloader also owns an unsendable HTTP client.
Future<String> _checksumInWorker(String path) =>
    Isolate.run(() => _checksum(path));

class GemmaModelStore implements AnalysisModelStore {
  GemmaModelStore({
    Future<Directory> Function()? supportDirectory,
    HttpClient Function()? createClient,
    MethodChannel? device,
    this.expectedBytes = GemmaModelSpec.bytes,
    this.expectedSha256 = GemmaModelSpec.sha256Hex,
    Uri? downloadUrl,
  }) : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _createClient = createClient ?? HttpClient.new,
       _device = device ?? const MethodChannel('dev.camereon/analysis_device'),
       _downloadUrl = downloadUrl ?? Uri.parse(GemmaModelSpec.url);

  final Future<Directory> Function() _supportDirectory;
  final HttpClient Function() _createClient;
  final MethodChannel _device;
  final Uri _downloadUrl;
  final int expectedBytes;
  final String expectedSha256;
  HttpClient? _client;
  bool _downloading = false;
  int _generation = 0;
  String? _verifiedStamp;
  Future<bool>? _verification;

  Future<File> get modelFile async {
    final root = await _supportDirectory();
    return File('${root.path}/ai/models/${GemmaModelSpec.filename}');
  }

  @override
  Future<bool> isReady() => _verification ??= _inspectReady().whenComplete(() {
    _verification = null;
  });

  Future<bool> _inspectReady() async {
    final file = await modelFile;
    if (!await file.exists()) return false;
    final stat = await file.stat();
    if (stat.size != expectedBytes) return false;
    final stamp =
        '${file.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    if (_verifiedStamp == stamp) return true;
    final path = file.path;
    if (await _checksumInWorker(path) != expectedSha256) {
      return false;
    }
    _verifiedStamp = stamp;
    return true;
  }

  Future<String> verifiedPath() async {
    if (!await isReady()) {
      throw const AnalysisFailure(AnalysisFailureKind.missingModel);
    }
    return (await modelFile).path;
  }

  @override
  int get downloadSize => expectedBytes;

  Map<String, Object> get _partialIdentity => {
    'url': _downloadUrl.toString(),
    'bytes': expectedBytes,
    'sha256': expectedSha256,
  };

  Future<int?> _partialLength(File target) async {
    try {
      final identity = jsonDecode(
        await File('${target.path}.part.json').readAsString(),
      );
      if (identity is! Map ||
          _partialIdentity.entries.any((e) => identity[e.key] != e.value)) {
        return null;
      }
      final length = await File('${target.path}.part').length();
      return length <= expectedBytes ? length : null;
    } on FileSystemException {
      return null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<int> downloadedBytes() async =>
      await _partialLength(await modelFile) ?? 0;

  Future<void> _clearPartial(File target) async {
    for (final suffix in ['.part', '.part.json', '.part.json.tmp']) {
      final file = File('${target.path}$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  @override
  Future<void> download({
    required void Function(int received, int total) onProgress,
  }) async {
    if (_downloading) throw const AnalysisFailure(AnalysisFailureKind.busy);
    _downloading = true;
    final generation = ++_generation;
    File? target;
    IOSink? sink;
    HttpClient? client;
    var discardPartial = false;
    void checkCancelled() {
      if (generation != _generation) throw const AnalysisCancelled();
    }

    try {
      target = await modelFile;
      await target.parent.create(recursive: true);
      final partial = File('${target.path}.part');
      final previousLength = await _partialLength(target);
      if (previousLength == null) await _clearPartial(target);
      var received = previousLength ?? 0;
      onProgress(received, expectedBytes);
      checkCancelled();
      final free = await _device.invokeMethod<int>('availableStorageBytes');
      checkCancelled();
      if (free == null ||
          free < expectedBytes - received + GemmaModelSpec.workingBytes) {
        throw const AnalysisFailure(AnalysisFailureKind.storage);
      }
      if (previousLength == null) {
        final identity = File('${target.path}.part.json.tmp');
        await identity.writeAsString(jsonEncode(_partialIdentity), flush: true);
        await identity.rename('${target.path}.part.json');
      }
      if (received < expectedBytes) {
        client = _createClient()
          ..connectionTimeout = const Duration(seconds: 30)
          ..autoUncompress = false;
        _client = client;
        final request = await client.getUrl(_downloadUrl);
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (received > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$received-');
        }
        checkCancelled();
        final response = await request.close().timeout(
          const Duration(seconds: 60),
        );
        checkCancelled();
        if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
          throw const AnalysisFailure(AnalysisFailureKind.integrity);
        }
        if (response.statusCode == HttpStatus.partialContent) {
          final range = RegExp(r'^bytes (\d+)-(\d+)/(\d+)$').firstMatch(
            response.headers.value(HttpHeaders.contentRangeHeader) ?? '',
          );
          if (range == null ||
              int.parse(range[1]!) != received ||
              int.parse(range[2]!) != expectedBytes - 1 ||
              int.parse(range[3]!) != expectedBytes) {
            // No new bytes have been written: retain the known prefix.
            throw const AnalysisFailure(AnalysisFailureKind.network);
          }
        } else if (response.statusCode == HttpStatus.ok) {
          // Some servers ignore Range. Never append a full response to a prefix.
          received = 0;
          onProgress(received, expectedBytes);
        } else {
          throw const AnalysisFailure(AnalysisFailureKind.network);
        }
        final encoding = response.headers.value(
          HttpHeaders.contentEncodingHeader,
        );
        if (encoding != null && encoding != 'identity') {
          throw const AnalysisFailure(AnalysisFailureKind.network);
        }
        if (response.contentLength >= 0 &&
            response.contentLength != expectedBytes - received) {
          throw const AnalysisFailure(AnalysisFailureKind.integrity);
        }
        sink = partial.openWrite(
          mode: received > 0 ? FileMode.append : FileMode.write,
        );
        var buffered = 0;
        var lastProgress = DateTime.now();
        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
        )) {
          checkCancelled();
          received += chunk.length;
          if (received > expectedBytes) {
            throw const AnalysisFailure(AnalysisFailureKind.integrity);
          }
          sink.add(chunk);
          buffered += chunk.length;
          // Bound pending writes without flushing on every network packet.
          if (buffered >= 1024 * 1024) {
            await sink.flush();
            buffered = 0;
          }
          if (DateTime.now().difference(lastProgress).inMilliseconds > 150) {
            onProgress(received, expectedBytes);
            lastProgress = DateTime.now();
          }
        }
        await sink.close();
        sink = null;
        checkCancelled();
        onProgress(received, expectedBytes);
        if (received != expectedBytes) {
          // A truncated transfer is resumable, not evidence of a bad prefix.
          throw const AnalysisFailure(AnalysisFailureKind.network);
        }
      }
      checkCancelled();
      onProgress(received, expectedBytes);
      if (await _checksumInWorker(partial.path) != expectedSha256) {
        throw const AnalysisFailure(AnalysisFailureKind.integrity);
      }
      checkCancelled();
      await partial.rename(target.path);
      await _clearPartial(target);
      final stat = await target.stat();
      _verifiedStamp =
          '${target.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } on AnalysisFailure catch (error) {
      discardPartial = error.kind == AnalysisFailureKind.integrity;
      rethrow;
    } on AnalysisCancelled {
      rethrow;
    } on FileSystemException {
      if (generation != _generation) throw const AnalysisCancelled();
      throw const AnalysisFailure(AnalysisFailureKind.storage);
    } catch (_) {
      if (generation != _generation) throw const AnalysisCancelled();
      throw const AnalysisFailure(AnalysisFailureKind.network);
    } finally {
      client?.close(force: true);
      try {
        await sink?.close();
      } catch (_) {
        // Keep the persisted prefix; final SHA-256 still gates publication.
      }
      try {
        if (discardPartial && target != null) await _clearPartial(target);
      } finally {
        if (identical(_client, client)) _client = null;
        _downloading = false;
      }
    }
  }

  @override
  void cancelDownload() {
    ++_generation;
    _client?.close(force: true);
  }

  @override
  Future<void> delete() async {
    if (_downloading || _verification != null) {
      throw const AnalysisFailure(AnalysisFailureKind.busy);
    }
    _verifiedStamp = null;
    final file = await modelFile;
    if (await file.exists()) await file.delete();
    await _clearPartial(file);
    // LiteRT-LM keeps its derived caches in Application Support, not in models/.
    final root = await _supportDirectory();
    await for (final entity in root.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && name.startsWith('${GemmaModelSpec.filename}_')) {
        await entity.delete();
      }
    }
  }
}
