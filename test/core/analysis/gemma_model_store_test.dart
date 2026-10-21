import 'dart:async';
import 'dart:io';

import 'package:camereon/core/analysis/infrastructure/gemma_model_store.dart';
import 'package:camereon/core/analysis/scene_analysis.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

class Headers implements HttpHeaders {
  Headers([Map<String, String> values = const {}]) : values = Map.of(values);
  final Map<String, String> values;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Response extends Stream<List<int>> implements HttpClientResponse {
  Response(
    this.chunks, {
    this.statusCode = 200,
    this.contentLength = 4,
    Map<String, String> headers = const {},
    this.delay = Duration.zero,
  }) : headers = Headers(headers);
  final Duration delay;
  @override
  final Headers headers;
  Stream<List<int>> get stream async* {
    for (final chunk in chunks) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      yield chunk;
    }
  }

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
  }) => stream.listen(
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
  final Headers headers = Headers();
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
  final sentHeaders = <Headers>[];
  @override
  set autoUncompress(bool value) {}
  bool closed = false;
  @override
  set connectionTimeout(Duration? timeout) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    requests++;
    final request = Request(response);
    sentHeaders.add(request.headers);
    return request;
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

  test('interrupted transfer resumes after a new store is created', () async {
    client.response = Response([
      [1, 2],
    ], contentLength: -1);
    await expectLater(
      store.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.network)),
    );
    expect(await store.downloadedBytes(), 2);
    final resumed = GemmaModelStore(
      supportDirectory: () async => root,
      createClient: () => client,
      device: channel,
      expectedBytes: 4,
      expectedSha256: sha256.convert([1, 2, 3, 4]).toString(),
      downloadUrl: Uri.parse('https://example.invalid/model'),
    );
    client.response = Response(
      [
        [3, 4],
      ],
      statusCode: 206,
      contentLength: 2,
      headers: {'content-range': 'bytes 2-3/4'},
    );
    final progress = <int>[];
    // Only the remaining bytes plus working space are required.
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => GemmaModelSpec.workingBytes + 2,
    );
    await resumed.download(onProgress: (received, _) => progress.add(received));
    expect(client.sentHeaders.last.value('range'), 'bytes=2-');
    expect(progress.first, 2);
    expect(progress.last, 4);
    expect(await resumed.isReady(), isTrue);
    expect(await resumed.downloadedBytes(), 0);
    expect(
      await File('${(await resumed.modelFile).path}.part.json').exists(),
      isFalse,
    );
  });

  test('pause preserves the prefix and resumes with HTTP Range', () async {
    client.response = Response([
      [1, 2],
      [3, 4],
    ], delay: const Duration(milliseconds: 180));
    await expectLater(
      store.download(
        onProgress: (received, _) {
          if (received == 2) store.cancelDownload();
        },
      ),
      throwsA(isA<AnalysisCancelled>()),
    );
    expect(await store.downloadedBytes(), 2);
    expect(await store.isReady(), isFalse);
    client.response = Response(
      [
        [3, 4],
      ],
      statusCode: 206,
      contentLength: 2,
      headers: {'content-range': 'bytes 2-3/4'},
    );
    await store.download(onProgress: (_, _) {});
    expect(client.sentHeaders.last.value('range'), 'bytes=2-');
    expect(await store.isReady(), isTrue);
  });

  test(
    'a server ignoring Range is restarted without duplicating the prefix',
    () async {
      client.response = Response([
        [1, 2],
      ], contentLength: -1);
      await expectLater(
        store.download(onProgress: (_, _) {}),
        throwsA(failure(AnalysisFailureKind.network)),
      );
      client.response = Response([
        [1, 2, 3, 4],
      ]);
      final progress = <int>[];
      await store.download(onProgress: (bytes, _) => progress.add(bytes));
      expect(progress.take(2), [2, 0]);
      expect(await File(await store.verifiedPath()).readAsBytes(), [
        1,
        2,
        3,
        4,
      ]);
    },
  );

  test('a wrong Content-Range cannot be appended to a saved prefix', () async {
    client.response = Response([
      [1, 2],
    ], contentLength: -1);
    await expectLater(
      store.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.network)),
    );
    client.response = Response(
      [
        [3, 4],
      ],
      statusCode: 206,
      contentLength: 2,
      headers: {'content-range': 'bytes 0-1/4'},
    );
    await expectLater(
      store.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.network)),
    );
    expect(await store.downloadedBytes(), 2);
    expect(await File('${(await store.modelFile).path}.part').readAsBytes(), [
      1,
      2,
    ]);
    await store.delete();
    expect(await store.downloadedBytes(), 0);
  });

  test(
    'a complete paused file is verified without another network transfer',
    () async {
      await expectLater(
        store.download(
          onProgress: (received, _) {
            if (received == 4) store.cancelDownload();
          },
        ),
        throwsA(isA<AnalysisCancelled>()),
      );
      expect(await store.downloadedBytes(), 4);
      final requests = client.requests;
      await store.download(onProgress: (_, _) {});
      expect(client.requests, requests);
      expect(await store.isReady(), isTrue);
    },
  );

  test(
    'a checksum mismatch after resume discards the corrupt checkpoint',
    () async {
      client.response = Response([
        [9, 9],
      ], contentLength: -1);
      await expectLater(
        store.download(onProgress: (_, _) {}),
        throwsA(failure(AnalysisFailureKind.network)),
      );
      client.response = Response(
        [
          [3, 4],
        ],
        statusCode: 206,
        contentLength: 2,
        headers: {'content-range': 'bytes 2-3/4'},
      );
      await expectLater(
        store.download(onProgress: (_, _) {}),
        throwsA(failure(AnalysisFailureKind.integrity)),
      );
      expect(await store.downloadedBytes(), 0);
      expect(
        await File('${(await store.modelFile).path}.part').exists(),
        isFalse,
      );
    },
  );

  test(
    'an update preserves the legacy partial of the pinned production model',
    () async {
      final production = GemmaModelStore(
        supportDirectory: () async => root,
        createClient: () => client,
        device: channel,
      );
      final target = await production.modelFile;
      await target.parent.create(recursive: true);
      await File('${target.path}.part').writeAsBytes([1, 2]);
      expect(await production.downloadedBytes(), 2);
      await expectLater(
        production.download(
          onProgress: (received, _) {
            expect(received, 2);
            production.cancelDownload();
          },
        ),
        throwsA(isA<AnalysisCancelled>()),
      );
      expect(await production.downloadedBytes(), 2);
      expect(client.requests, 0);
      // A custom/different model cannot adopt that unlabelled checkpoint.
      expect(await store.downloadedBytes(), 0);
    },
  );

  test('a checkpoint with a different identity is restarted safely', () async {
    client.response = Response([
      [1, 2],
    ], contentLength: -1);
    await expectLater(
      store.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.network)),
    );
    final target = await store.modelFile;
    await File('${target.path}.part.json').writeAsString('{}');
    expect(await store.downloadedBytes(), 0);
    client.response = Response([
      [1, 2, 3, 4],
    ]);
    await store.download(onProgress: (_, _) {});
    expect(client.sentHeaders.last.value('range'), isNull);
    expect(await store.isReady(), isTrue);
  });

  test('real HTTP streaming resumes a truncated body using Range', () async {
    final ranges = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      ranges.add(request.headers.value(HttpHeaders.rangeHeader));
      if (ranges.length == 1) {
        request.response.add([1, 2]);
      } else {
        request.response.statusCode = HttpStatus.partialContent;
        request.response.headers.set(
          HttpHeaders.contentRangeHeader,
          'bytes 2-3/4',
        );
        request.response.contentLength = 2;
        request.response.add([3, 4]);
      }
      await request.response.close();
    });
    GemmaModelStore freshStore() => GemmaModelStore(
      supportDirectory: () async => root,
      createClient: () => _RealHttp().createHttpClient(null),
      device: channel,
      expectedBytes: 4,
      expectedSha256: sha256.convert([1, 2, 3, 4]).toString(),
      downloadUrl: Uri.parse('http://127.0.0.1:${server.port}/model'),
    );
    final first = freshStore();
    await expectLater(
      first.download(onProgress: (_, _) {}),
      throwsA(failure(AnalysisFailureKind.network)),
    );
    expect(await first.downloadedBytes(), 2);
    final resumed = freshStore();
    await resumed.download(onProgress: (_, _) {});
    expect(ranges, [null, 'bytes=2-']);
    expect(await File(await resumed.verifiedPath()).readAsBytes(), [
      1,
      2,
      3,
      4,
    ]);
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
