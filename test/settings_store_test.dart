import 'dart:convert';
import 'dart:io';

import 'package:camereon/core/detection/address_detection_mode.dart';
import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/features/settings/app_settings.dart';
import 'package:camereon/features/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late FileSettingsStore store;
  File file() => File('${dir.path}/${FileSettingsStore.fileName}');

  setUp(() {
    dir = Directory.systemTemp.createTempSync('camereon-settings');
    store = FileSettingsStore(directory: () async => dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('defaults keep the current behavior', () {
    const settings = AppSettings();
    expect(settings.autoHideKinds, {
      CandidateKind.address,
      CandidateKind.phone,
      CandidateKind.face,
    });
    expect(settings.resolution.preset.name, 'veryHigh');
    expect(settings.showGrid, isFalse);
  });

  test('legacy address switch migrates to its corresponding mode', () {
    for (final hide in [true, false]) {
      final settings = AppSettings.fromJson({
        'autoHide': {'address': hide},
      });
      expect(
        settings.addressMode,
        hide ? AddressDetectionMode.placeNames : AddressDetectionMode.off,
      );
    }
  });

  test('a missing file reads as the defaults', () async {
    expect(await store.load(), const AppSettings());
  });

  test('saved settings read back the same', () async {
    final settings = const AppSettings()
        .withAutoHide(CandidateKind.face, false)
        .copyWith(
          addressMode: AddressDetectionMode.addressOnly,
          resolution: CameraResolution.uhd,
          showGrid: true,
        );
    await store.save(settings);
    expect(await store.load(), settings);
    expect(await store.load(), isNot(const AppSettings()));
    expect(
      File('${file().path}.tmp').existsSync(),
      isFalse,
      reason: 'the write is swapped into place',
    );

    await store.save(settings.withAutoHide(CandidateKind.face, true));
    expect((await store.load()).autoHideKinds, contains(CandidateKind.face));
  });

  test('saving creates a missing directory', () async {
    final nested = Directory('${dir.path}/not/yet');
    final store = FileSettingsStore(directory: () async => nested);
    await store.save(const AppSettings(showGrid: true));
    expect((await store.load()).showGrid, isTrue);
  });

  for (final (name, bytes) in [
    ('broken JSON', utf8.encode('{"grid": tr')),
    ('empty', <int>[]),
    ('not an object', utf8.encode('[1, 2]')),
    ('not UTF-8', [0xff, 0xfe, 0x00, 0x80]),
  ]) {
    test('a corrupt file ($name) reads as the defaults', () async {
      file().writeAsBytesSync(bytes);
      expect(await store.load(), const AppSettings());
    });
  }

  test('malformed fields fall back one by one', () async {
    file().writeAsStringSync(
      jsonEncode({
        'autoHide': {'address': 'no', 'face': false, 'phone': false},
        'resolution': 'gigapixel',
        'grid': true,
      }),
    );
    final settings = await store.load();
    expect(settings.autoHideKinds, {CandidateKind.address});
    expect(settings.resolution, CameraResolution.fullHd);
    expect(settings.showGrid, isTrue);
  });

  test('a kind missing from the file stays hidden automatically', () async {
    file().writeAsStringSync(jsonEncode({'autoHide': {}}));
    expect(
      (await store.load()).autoHideKinds,
      const AppSettings().autoHideKinds,
    );
  });

  test('an unavailable directory reads as the defaults', () async {
    final store = FileSettingsStore(
      directory: () async => throw const FileSystemException('unavailable'),
    );
    expect(await store.load(), const AppSettings());
  });

  test(
    'the controller applies changes at once and saves them in order',
    () async {
      final memory = MemorySettingsStore();
      final controller = SettingsController(memory);
      addTearDown(controller.dispose);
      var notified = 0;
      controller.addListener(() => notified++);

      controller.update(controller.value.copyWith(showGrid: true));
      controller.update(controller.value.copyWith(showGrid: true));
      controller.update(
        controller.value.withAutoHide(CandidateKind.address, false),
      );
      expect(controller.value.showGrid, isTrue);
      expect(controller.value.autoHideKinds, {
        CandidateKind.phone,
        CandidateKind.face,
      });
      expect(notified, 2);

      await controller.saved;
      expect(memory.saves, 2);
      expect(memory.saved, controller.value);

      final reloaded = SettingsController(memory);
      addTearDown(reloaded.dispose);
      await reloaded.load();
      expect(reloaded.value, controller.value);
    },
  );

  test('a failed save keeps the change for this run', () async {
    final controller = SettingsController(
      FileSettingsStore(
        directory: () async => throw const FileSystemException('read-only'),
      ),
    );
    addTearDown(controller.dispose);
    controller.update(const AppSettings(showGrid: true));
    await controller.saved;
    expect(controller.value.showGrid, isTrue);
  });
}
