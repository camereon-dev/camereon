// Run both suites in one device session to avoid restarting Xcode between them.
import 'ios_real_detection_test.dart' as detection;
import 'photo_edit_save_test.dart' as editing;

void main() {
  detection.main();
  editing.main();
}
