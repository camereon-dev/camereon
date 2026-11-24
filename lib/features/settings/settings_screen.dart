import 'package:flutter/material.dart';

import '../camera/glass_photo_chrome.dart';
import 'app_settings.dart';
import 'settings_store.dart';

/// Changes apply as soon as they are made; there is nothing to confirm.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.settings});

  final SettingsController settings;

  static Widget _resolutionTile(CameraResolution resolution) {
    final (title, note) = switch (resolution) {
      CameraResolution.hd => ('軽量（720p）', '小さな文字は見つけにくくなります'),
      CameraResolution.fullHd => ('標準（1080p）', null),
      CameraResolution.uhd => ('高画質（4K）', '細かな文字まで写ります。仕上げに時間がかかります'),
    };
    return RadioListTile<CameraResolution>(
      key: ValueKey('resolution-${resolution.name}'),
      value: resolution,
      title: Text(title),
      subtitle: note == null ? null : Text(note),
    );
  }

  // Callbacks read the live value: two quick taps must not undo each other.
  void _update(AppSettings Function(AppSettings) change) =>
      settings.update(change(settings.value));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(backgroundColor: Colors.black, title: const Text('設定')),
      body: ValueListenableBuilder<AppSettings>(
        valueListenable: settings,
        builder: (context, current, _) => Column(
          children: [
            if (settings.saveFailed)
              MaterialBanner(
                content: Semantics(
                  liveRegion: true,
                  child: const Text('設定を保存できませんでした。アプリを閉じると変更が失われます。'),
                ),
                actions: [
                  TextButton(
                    onPressed: settings.retrySave,
                    child: const Text('再試行'),
                  ),
                ],
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 24),
                children: [
                  const _Heading(
                    '自動で隠す',
                    note:
                        '写真から見つけたとき、最初から隠しておくもの。'
                        'オフにしても枠は表示され、タップすれば隠せます。',
                  ),
                  for (final kind in autoHideChoices)
                    SwitchListTile(
                      key: ValueKey('auto-hide-${kind.name}'),
                      title: Text(kind.label),
                      value: current.autoHideKinds.contains(kind),
                      onChanged: (hide) =>
                          _update((s) => s.withAutoHide(kind, hide)),
                    ),
                  const _Heading('カメラ'),
                  const _Heading(
                    '解像度',
                    sub: true,
                    note: '端末が対応していない場合は、近い解像度で撮影します。',
                  ),
                  RadioGroup<CameraResolution>(
                    groupValue: current.resolution,
                    onChanged: (resolution) {
                      if (resolution == null) return;
                      _update((s) => s.copyWith(resolution: resolution));
                    },
                    child: Column(
                      children: [
                        for (final resolution in CameraResolution.values)
                          _resolutionTile(resolution),
                      ],
                    ),
                  ),
                  SwitchListTile(
                    key: const ValueKey('camera-grid-setting'),
                    title: const Text('グリッド'),
                    subtitle: const Text('プレビューに縦横3分割の線を表示します'),
                    value: current.showGrid,
                    onChanged: (show) =>
                        _update((s) => s.copyWith(showGrid: show)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.title, {this.note, this.sub = false});

  final String title;
  final String? note;

  /// A label inside a section rather than the section itself.
  final bool sub;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = this.note;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, sub ? 12 : 28, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            header: true,
            child: Text(
              title,
              style: sub
                  ? theme.textTheme.titleSmall
                  : theme.textTheme.titleSmall?.copyWith(
                      color: glassMint,
                      fontWeight: FontWeight.w700,
                    ),
            ),
          ),
          if (note != null) ...[
            const SizedBox(height: 6),
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: Colors.white70,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
