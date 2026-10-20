import 'dart:async';
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

class GemmaModelStore implements AnalysisModelStore {
  static const _device = MethodChannel('dev.camereon/analysis_device');
  HttpClient? _client;
  bool _downloading = false;
  int _generation = 0;
  String? _verifiedStamp;
  Future<bool>? _verification;

  Future<File> get modelFile async {
    final root = await getApplicationSupportDirectory();
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
    if (stat.size != GemmaModelSpec.bytes) return false;
    final stamp =
        '${file.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    if (_verifiedStamp == stamp) return true;
    final path = file.path;
    if (await Isolate.run(() => _checksum(path)) != GemmaModelSpec.sha256Hex) {
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
  Future<void> download({
    required void Function(int received, int total) onProgress,
  }) async {
    if (_downloading) throw const AnalysisFailure(AnalysisFailureKind.busy);
    _downloading = true;
    final generation = ++_generation;
    File? partial;
    IOSink? sink;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 30);
    _client = client;
    void checkCancelled() {
      if (generation != _generation) throw const AnalysisCancelled();
    }

    try {
      final free = await _device.invokeMethod<int>('availableStorageBytes');
      checkCancelled();
      if (free == null ||
          free < GemmaModelSpec.bytes + GemmaModelSpec.workingBytes) {
        throw const AnalysisFailure(AnalysisFailureKind.storage);
      }
      final target = await modelFile;
      await target.parent.create(recursive: true);
      partial = File('${target.path}.part');
      final request = await client.getUrl(Uri.parse(GemmaModelSpec.url));
      final response = await request.close().timeout(
        const Duration(seconds: 60),
      );
      if (response.statusCode != HttpStatus.ok) {
        throw const AnalysisFailure(AnalysisFailureKind.network);
      }
      if (response.contentLength >= 0 &&
          response.contentLength != GemmaModelSpec.bytes) {
        throw const AnalysisFailure(AnalysisFailureKind.integrity);
      }
      sink = partial.openWrite();
      var received = 0;
      var lastProgress = DateTime.now();
      onProgress(0, GemmaModelSpec.bytes);
      await for (final chunk in response.timeout(const Duration(seconds: 60))) {
        checkCancelled();
        received += chunk.length;
        if (received > GemmaModelSpec.bytes) {
          throw const AnalysisFailure(AnalysisFailureKind.integrity);
        }
        sink.add(chunk);
        // Apply backpressure; do not queue a multi-GB file in memory.
        await sink.flush();
        if (DateTime.now().difference(lastProgress).inMilliseconds > 150) {
          onProgress(received, GemmaModelSpec.bytes);
          lastProgress = DateTime.now();
        }
      }
      await sink.close();
      sink = null;
      checkCancelled();
      onProgress(received, GemmaModelSpec.bytes);
      if (received != GemmaModelSpec.bytes) {
        throw const AnalysisFailure(AnalysisFailureKind.integrity);
      }
      final path = partial.path;
      if (await Isolate.run(() => _checksum(path)) !=
          GemmaModelSpec.sha256Hex) {
        throw const AnalysisFailure(AnalysisFailureKind.integrity);
      }
      checkCancelled();
      await partial.rename(target.path);
      _verifiedStamp = null;
      // Mark ready only after a verified file is atomically published.
      final stat = await target.stat();
      _verifiedStamp =
          '${target.path}:${stat.size}:${stat.modified.microsecondsSinceEpoch}';
    } on AnalysisFailure {
      rethrow;
    } on AnalysisCancelled {
      rethrow;
    } catch (_) {
      if (generation != _generation) throw const AnalysisCancelled();
      throw const AnalysisFailure(AnalysisFailureKind.network);
    } finally {
      client.close(force: true);
      try {
        await sink?.close();
      } catch (_) {
        /* Already closed on failure. */
      }
      try {
        if (partial != null && await partial.exists()) await partial.delete();
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
    if (_downloading) throw const AnalysisFailure(AnalysisFailureKind.busy);
    _verifiedStamp = null;
    final file = await modelFile;
    if (await file.exists()) await file.delete();
    final partial = File('${file.path}.part');
    if (await partial.exists()) await partial.delete();
    // LiteRT-LM keeps its derived caches in Application Support, not in models/.
    final root = await getApplicationSupportDirectory();
    await for (final entity in root.list(followLinks: false)) {
      final name = entity.uri.pathSegments.last;
      if (entity is File && name.startsWith('${GemmaModelSpec.filename}_')) {
        await entity.delete();
      }
    }
  }
}
