/// 開発用: 撮影なしで本体と同じ解析画面・サービスを確認する。
/// `flutter run -t lib/analysis_demo.dart -d <android-device>`
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'features/analysis/photo_analysis_screen.dart';

void main() {
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF235C43),
          brightness: Brightness.dark,
        ),
      ),
      home: PhotoAnalysisScreen(
        loadImage: () async {
          final data = await rootBundle.load(
            'tools/vlm-eval/fixtures/parcel_ja.png',
          );
          return data.buffer.asUint8List(
            data.offsetInBytes,
            data.lengthInBytes,
          );
        },
      ),
    ),
  );
}
