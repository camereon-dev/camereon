import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/analysis/analysis_services.dart';
import '../../core/photo/photo_images.dart';
import 'photo_analysis_screen.dart';

/// Analysis uses the exact pixels successfully loaded by the editor.
class PhotoAnalysisEntry extends StatefulWidget {
  const PhotoAnalysisEntry({
    super.key,
    this.child,
    this.editorBuilder,
    required this.loadImage,
    this.services,
  }) : assert((child == null) != (editorBuilder == null));

  final Widget? child;
  final Widget Function(ValueChanged<SourcePhoto> onSourceLoaded)?
  editorBuilder;
  final Future<Uint8List> Function() loadImage;
  final AnalysisServices? services;

  @override
  State<PhotoAnalysisEntry> createState() => _PhotoAnalysisEntryState();
}

class _PhotoAnalysisEntryState extends State<PhotoAnalysisEntry> {
  bool _covered = false;
  SourcePhoto? _source;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: AnalysisEntryVisibility(
      covered: _covered,
      child:
          widget.editorBuilder?.call(
            (source) => setState(() => _source = source),
          ) ??
          widget.child!,
    ),
    bottomNavigationBar: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
        child: FilledButton.icon(
          onPressed:
              _covered || (widget.editorBuilder != null && _source == null)
              ? null
              : () async {
                  setState(() => _covered = true);
                  try {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => PhotoAnalysisScreen(
                          loadImage: () async =>
                              _source?.bytes ?? await widget.loadImage(),
                          services: widget.services,
                        ),
                      ),
                    );
                  } finally {
                    if (mounted) setState(() => _covered = false);
                  }
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
