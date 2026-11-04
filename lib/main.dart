import 'package:flutter/widgets.dart';

import 'app.dart';
import 'features/camera/capture_files.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Finish cleanup before the camera can create a new capture.
  await deleteLeftoverCaptures();
  runApp(const CamereonApp());
}
