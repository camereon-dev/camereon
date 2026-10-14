import 'dart:async';

import 'package:flutter/widgets.dart';

import 'app.dart';
import 'features/camera/capture_files.dart';

void main() {
  runApp(const CamereonApp());
  unawaited(deleteLeftoverCaptures());
}
