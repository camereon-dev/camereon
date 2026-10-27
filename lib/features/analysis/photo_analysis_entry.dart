import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/analysis/analysis_services.dart';
import 'photo_analysis_screen.dart';

/// #9 の編集画面を変更せず、撮影後の画面に解析への入口を合成する。
class PhotoAnalysisEntry extends StatelessWidget {
  const PhotoAnalysisEntry({
    super.key,
    required this.child,
    required this.loadImage,
    this.services,
  });
  final Widget child;
  final Future<Uint8List> Function() loadImage;
  final AnalysisServices? services;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: child,
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
        child: FilledButton.icon(
          onPressed: () => Navigator.of(context).push<void>(
            MaterialPageRoute(
              builder: (_) =>
                  PhotoAnalysisScreen(loadImage: loadImage, services: services),
            ),
          ),
          icon: const Icon(Icons.auto_awesome_rounded),
          label: const Text('端末内で写真を解析'),
        ),
      ),
    ),
  );
}
