import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/analysis/analysis_services.dart';
import 'photo_analysis_screen.dart';

/// #9 の編集画面を変更せず、撮影後の画面に解析への入口を合成する。
class PhotoAnalysisEntry extends StatefulWidget {
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
  State<PhotoAnalysisEntry> createState() => _PhotoAnalysisEntryState();
}

class _PhotoAnalysisEntryState extends State<PhotoAnalysisEntry> {
  bool _covered = false;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: AnalysisEntryVisibility(covered: _covered, child: widget.child),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
        child: FilledButton.icon(
          onPressed: _covered
              ? null
              : () async {
                  setState(() => _covered = true);
                  await Navigator.of(context).push<void>(
                    MaterialPageRoute(
                      builder: (_) => PhotoAnalysisScreen(
                        loadImage: widget.loadImage,
                        services: widget.services,
                      ),
                    ),
                  );
                  if (mounted) setState(() => _covered = false);
                },
          icon: const Icon(Icons.auto_awesome_rounded),
          label: const Text('端末内で写真を解析'),
        ),
      ),
    ),
  );
}

class AnalysisEntryVisibility extends InheritedWidget {
  const AnalysisEntryVisibility({
    super.key,
    required this.covered,
    required super.child,
  });
  final bool covered;
  static bool coveredOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AnalysisEntryVisibility>()
          ?.covered ??
      false;
  @override
  bool updateShouldNotify(AnalysisEntryVisibility oldWidget) =>
      covered != oldWidget.covered;
}
