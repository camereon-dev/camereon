import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';
import 'package:camereon/features/detection/candidate_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'editor_support.dart';

/// Production-like editor flow on a staged photo: open, wait for every
/// detector, hide everything with one chip, wait for the frosted previews,
/// confirm. Reports phase timings; memory is sampled from the host.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'editor flow: detect, hide all, preview, confirm',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/blackboard-eval');
      final manifest = File('${dir.path}/sources.json');
      await tester.runAsync(() async {
        final end = DateTime.now().add(const Duration(minutes: 3));
        while (!await manifest.exists()) {
          if (DateTime.now().isAfter(end)) throw StateError('Stage fixtures');
          await Future<void>.delayed(const Duration(seconds: 1));
        }
      });
      final sources = (jsonDecode(await manifest.readAsString()) as List)
          .cast<Map<String, dynamic>>();
      final report = <Map<String, Object>>[];
      for (final item in sources) {
        final id = item['id'] as String;
        final temp = File('${support.path}/editor-$id.jpg');
        await File('${dir.path}/$id.jpg').copy(temp.path);
        final opened = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(home: CapturedPhotoScreen(photo: XFile(temp.path))),
        );
        // Pump until every detector has finished (status leaves 検出中).
        Future<void> pumpUntil(bool Function() done, Duration limit) async {
          final end = DateTime.now().add(limit);
          while (!done()) {
            if (DateTime.now().isAfter(end)) throw StateError('timeout: $id');
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        await pumpUntil(
          () =>
              find.bySemanticsLabel('撮影した写真').evaluate().isNotEmpty &&
              find.text('検出中').evaluate().isEmpty &&
              find.text('写真を準備中').evaluate().isEmpty,
          const Duration(seconds: 90),
        );
        final detected = opened.elapsedMilliseconds;
        final candidates = tester
            .widget<CandidateOverlay>(find.byType(CandidateOverlay))
            .candidates;
        await tester.tap(find.byKey(const ValueKey('kind-chip-all')));
        await tester.pump();
        final hiding = Stopwatch()..start();
        SelectionPainter painter() =>
            tester
                    .widget<CustomPaint>(
                      find.byWidgetPredicate(
                        (w) =>
                            w is CustomPaint && w.painter is SelectionPainter,
                      ),
                    )
                    .painter!
                as SelectionPainter;
        await pumpUntil(
          () => painter().patches.length >= painter().regions.length,
          const Duration(seconds: 120),
        );
        final previewed = hiding.elapsedMilliseconds;
        final confirming = Stopwatch()..start();
        await editorAction(tester, '保存前に確認');
        await pumpUntil(
          () => find.bySemanticsLabel('保存する加工済み写真').evaluate().isNotEmpty,
          const Duration(seconds: 120),
        );
        final confirmed = confirming.elapsedMilliseconds;
        report.add({
          'id': id,
          'candidates': candidates.length,
          'detect_ms': detected,
          'preview_patches_ms': previewed,
          'confirm_redact_ms': confirmed,
        });
        // ignore: avoid_print
        print('EDITOR_CASE ${jsonEncode(report.last)}');
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
      await File('${dir.path}/editor.json').writeAsString(jsonEncode(report));
      // ignore: avoid_print
      print('EDITOR_READY');
      await tester.runAsync(() async {
        final end = DateTime.now().add(const Duration(seconds: 90));
        while (!await File('${dir.path}/collected').exists()) {
          if (DateTime.now().isAfter(end)) throw StateError('Collect results');
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      });
    },
    skip: !const bool.fromEnvironment('RUN_EDITOR_FLOW_TEST'),
    timeout: Timeout.none,
  );
}
