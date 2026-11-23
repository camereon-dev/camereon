import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'app_settings.dart';

abstract interface class SettingsStore {
  /// Never throws: a missing or unreadable store yields the defaults.
  Future<AppSettings> load();
  Future<void> save(AppSettings settings);
}

/// A small JSON file in the application support directory.
class FileSettingsStore implements SettingsStore {
  FileSettingsStore({Future<Directory> Function()? directory})
    : _directory = directory ?? getApplicationSupportDirectory;

  static const fileName = 'settings.json';
  final Future<Directory> Function() _directory;

  Future<File> _file() async => File('${(await _directory()).path}/$fileName');

  @override
  Future<AppSettings> load() async {
    try {
      final file = await _file();
      if (!await file.exists()) return const AppSettings();
      return AppSettings.fromJson(jsonDecode(await file.readAsString()));
    } catch (e) {
      debugPrint('settings: using defaults, could not read: $e');
      return const AppSettings();
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    final file = await _file();
    await file.parent.create(recursive: true);
    // Write aside and swap, so a crash mid-write never leaves a torn file.
    final pending = File('${file.path}.tmp');
    await pending.writeAsString(jsonEncode(settings.toJson()), flush: true);
    await pending.rename(file.path);
  }
}

/// Keeps settings for this run only; used by tests and as a fallback.
class MemorySettingsStore implements SettingsStore {
  MemorySettingsStore([this.saved]);
  AppSettings? saved;
  int saves = 0;

  @override
  Future<AppSettings> load() async => saved ?? const AppSettings();

  @override
  Future<void> save(AppSettings settings) async {
    saves++;
    saved = settings;
  }
}

/// The current settings. Changes apply at once; writes follow in order.
class SettingsController extends ValueNotifier<AppSettings> {
  SettingsController(this._store, [super.value = const AppSettings()]);

  final SettingsStore _store;
  Future<void> _saving = Future.value();

  /// Completes when every change so far has been written (or failed).
  Future<void> get saved => _saving;

  Future<void> load() async {
    try {
      value = await _store.load();
    } catch (e) {
      debugPrint('settings: using defaults, could not load: $e');
    }
  }

  void update(AppSettings next) {
    if (next == value) return;
    value = next;
    _saving = _saving.then((_) => _store.save(next)).catchError((Object e) {
      // The change still applies for this run; only persistence is lost.
      debugPrint('settings: could not save: $e');
    });
  }
}
