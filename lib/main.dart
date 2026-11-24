import 'package:flutter/widgets.dart';

import 'app.dart';
import 'features/camera/capture_files.dart';
import 'features/settings/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = SettingsController(FileSettingsStore());
  // Finish cleanup before the camera can create a new capture, and read the
  // settings first so the camera opens once, at the chosen resolution.
  await Future.wait([deleteLeftoverCaptures(), settings.load()]);
  runApp(CamereonApp(settings: settings));
}
