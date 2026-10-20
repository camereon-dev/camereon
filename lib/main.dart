import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:camereon/features/camera/captured_photo_screen.dart';

void main() {
  // カメラの初期化や画面固定を行わず、直接アプリを起動
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Issue #9 黒塗りテスト',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: CapturedPhotoScreen(
        photo: XFile(''),
      ),
    );
  }
}
