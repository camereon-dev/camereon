import 'package:camereon/core/detection/region_detector.dart';
import 'package:camereon/features/settings/app_settings.dart';
import 'package:camereon/features/settings/settings_screen.dart';
import 'package:camereon/features/settings/settings_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late MemorySettingsStore store;
  late SettingsController settings;

  Future<void> open(WidgetTester tester, [AppSettings? initial]) async {
    store = MemorySettingsStore(initial);
    settings = SettingsController(store);
    addTearDown(settings.dispose);
    await settings.load();
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(settings: settings)),
    );
  }

  bool switchOn(WidgetTester tester, String key) =>
      tester.widget<SwitchListTile>(find.byKey(ValueKey(key))).value;

  testWidgets('shows a switch for each kind that can be hidden automatically', (
    tester,
  ) async {
    await open(tester);
    for (final kind in autoHideChoices) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey('auto-hide-${kind.name}')),
          matching: find.text(kind.label),
        ),
        findsOneWidget,
      );
      expect(switchOn(tester, 'auto-hide-${kind.name}'), isTrue);
    }
    expect(find.text('住所'), findsOneWidget);
    expect(find.text('顔'), findsOneWidget);
    expect(switchOn(tester, 'camera-grid-setting'), isFalse);
    expect(
      tester
          .widget<RadioGroup<CameraResolution>>(
            find.byType(RadioGroup<CameraResolution>),
          )
          .groupValue,
      CameraResolution.fullHd,
    );
  });

  testWidgets('auto-hide switches turn each kind off and on', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('auto-hide-face')));
    await tester.pump();
    expect(settings.value.autoHideKinds, {CandidateKind.address});
    expect(switchOn(tester, 'auto-hide-face'), isFalse);
    expect(switchOn(tester, 'auto-hide-address'), isTrue);

    await tester.tap(find.byKey(const ValueKey('auto-hide-address')));
    await tester.pump();
    expect(settings.value.autoHideKinds, isEmpty);

    await tester.tap(find.byKey(const ValueKey('auto-hide-face')));
    await tester.pump();
    expect(settings.value.autoHideKinds, {CandidateKind.face});
    await settings.saved;
    expect(store.saves, 3);
    expect(store.saved, settings.value);
  });

  testWidgets('camera settings change resolution and grid', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('resolution-uhd')));
    await tester.pump();
    expect(settings.value.resolution, CameraResolution.uhd);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('camera-grid-setting')),
      100,
    );
    await tester.tap(find.byKey(const ValueKey('camera-grid-setting')));
    await tester.pump();
    expect(settings.value.showGrid, isTrue);
    expect(switchOn(tester, 'camera-grid-setting'), isTrue);
    await settings.saved;
    expect(store.saved, settings.value);
  });

  testWidgets('opens with the saved settings', (tester) async {
    await open(
      tester,
      const AppSettings(
        resolution: CameraResolution.hd,
        showGrid: true,
      ).withAutoHide(CandidateKind.address, false),
    );
    await tester.pump();
    expect(switchOn(tester, 'auto-hide-address'), isFalse);
    expect(switchOn(tester, 'auto-hide-face'), isTrue);
    expect(switchOn(tester, 'camera-grid-setting'), isTrue);
    expect(
      tester
          .widget<RadioGroup<CameraResolution>>(
            find.byType(RadioGroup<CameraResolution>),
          )
          .groupValue,
      CameraResolution.hd,
    );
  });

  testWidgets('fits a small screen with large text', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await open(tester);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
