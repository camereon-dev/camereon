import 'dart:async';
import 'dart:io';

import 'package:camereon/core/analysis/infrastructure/gemma_model_store.dart';
import 'package:camereon/core/analysis/scene_analysis.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class Response extends Stream<List<int>> implements HttpClientResponse {
  Response(this.chunks, {this.statusCode = 200, this.contentLength = 4});
  final List<List<int>> chunks;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.fromIterable(chunks).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Request implements HttpClientRequest {
  Request(this.response);
  final Response response;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Client implements HttpClient {
  Response response = Response([
    [1, 2],
    [3, 4],
  ]);
  int requests = 0;
  bool closed = false;
  @override
  set connectionTimeout(Duration? timeout) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    return Request(response);
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Matcher failure(AnalysisFailureKind kind) =>
    isA<AnalysisFailure>().having((e) => e.kind, 'kind', kind);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/analysis-storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late Client client;
  late GemmaModelStore store;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('camereon-model-test-');
    client = Client();
    store = GemmaModelStore(
      supportDirectory: () async => root,
      createClient: () => client,
      device: channel,
      expectedBytes: 4,
      expectedSha256: sha256.convert([1, 2, 3, 4]).toString(),
      downloadUrl: Uri.parse('https://example.invalid/model'),
    );
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => 10 * 1024 * 1024 * 1024,
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test(
    'publishes only verified bytes, reports progress and cleans up',
    () async {
      final progress = <int>[];
      expect(await store.isReady(), isFalse);
      await store.download(onProgress: (received, _) => progress.add(received));
      expect(await store.isReady(), isTrue);
      expect(await File(await store.verifiedPath()).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
      expect(progress.first, 0);
      expect(progress.last, 4);
      expect(
        await File('${(await store.modelFile).path}.part').exists(),
        isFalse,
      );
      expect(client.closed, isTrue);
      await store.delete();
      expect(await store.isReady(), isFalse);
    },
  );

  for (final response in [
    Response([
      [9, 9, 9, 9],
    ]),
    Response([
      [1, 2],
    ], contentLength: -1),
    Response([
      [1, 2, 3, 4, 5],
    ], contentLength: -1),
    Response([
      [1, 2, 3, 4],
    ], contentLength: 9),
  ]) {
    test(
      'rejects corrupt or mismatched downloads without publishing',
      () async {
        client.response = response;
        await expectLater(
          store.download(onProgress: (_, _) {}),
          throwsA(failure(AnalysisFailureKind.integrity)),
        );
        expect(await store.isReady(), isFalse);
        expect(
          await File('${(await store.modelFile).path}.part').exists(),
          isFalse,
        );
      },
    );
  }

  test('insufficient storage avoids network access', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => 0);
    await expectLater(
      store.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.storage)),
    );
    expect(client.requests, 0);
  });

  test('network failure preserves the previously verified model', () async {
    await store.download(onProgress: (_, _) {});
    client.response = Response([], statusCode: 503);
    await expectLater(
      store.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.network)),
    );
    expect(await store.isReady(), isTrue);
  });

  test('cancel removes partial data and permits retry', () async {
    await expectLater(
      store.download(onProgress: (_, _) => store.cancelDownload()),
      throwsA(isA<AnalysisCancelled>()),
    );
    expect(await store.isReady(), isFalse);
    expect(
      await File('${(await store.modelFile).path}.part').exists(),
      isFalse,
    );
    await store.download(onProgress: (_, _) {});
    expect(await store.isReady(), isTrue);
  });

  test('simultaneous download and deletion are refused', () async {
    final pending = Completer<int>();
    messenger.setMockMethodCallHandler(channel, (_) => pending.future);
    final first = store.download(onProgress: (_, _) {});
    await expectLater(
      store.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.busy)),
    );
    await expectLater(
      store.delete(),
      throwsA(failure(AnalysisFailureKind.busy)),
    );
    pending.complete(10 * 1024 * 1024 * 1024);
    await first;
  });

  test('missing or corrupt local file cannot become verified', () async {
    await expectLater(
      store.verifiedPath(),
      throwsA(failure(AnalysisFailureKind.missingModel)),
    );
    final file = await store.modelFile;
    await file.parent.create(recursive: true);
    await file.writeAsBytes([9, 9, 9, 9]);
    expect(await store.isReady(), isFalse);
    await file.writeAsBytes([1]);
    expect(await store.isReady(), isFalse);
  });
}
