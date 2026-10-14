import 'package:flutter/material.dart';

import 'features/camera/camera_screen.dart';

class CamereonApp extends StatelessWidget {
  const CamereonApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'camereon',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF235C43),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: Colors.black,
      ),
      // 起動したらすぐ撮影できるよう、最初の画面をカメラにする
      home: const CameraScreen(),
    );
  }
}
