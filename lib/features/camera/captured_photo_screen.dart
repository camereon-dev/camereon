import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/photo/android_photo_saver.dart';
import '../../core/photo/hide_region.dart';
import '../../core/photo/flutter_photo_processor.dart';
import '../../core/photo/photo_images.dart';
import '../../core/photo/photo_processor.dart';
import '../../core/photo/photo_processing_exception.dart';
import '../../core/photo/photo_saver.dart';

/// 正規化した画像の画素座標で編集し、確認した JPEG だけを保存する。
class CapturedPhotoScreen extends StatefulWidget {
  const CapturedPhotoScreen({
    super.key,
    required this.photo,
    this.processor,
    this.saver,
  });

  final XFile photo;
  final PhotoProcessor? processor;
  final PhotoSaver? saver;

  @override
  State<CapturedPhotoScreen> createState() => _CapturedPhotoScreenState();
}

class _CapturedPhotoScreenState extends State<CapturedPhotoScreen> {
  late final PhotoProcessor _processor =
      widget.processor ?? FlutterPhotoProcessor();
  late final PhotoSaver _saver = widget.saver ?? AndroidPhotoSaver();
  SourcePhoto? _source;
  RedactedJpeg? _preview;
  final List<HideRegion> _regions = [];
  Offset? _start;
  HideRegion? _drag;
  bool _busy = true;
  bool _loadFailed = false;
  String _loadError = '写真を読み込めませんでした。撮り直すか再試行してください。';
  bool _processingFailed = false;
  int? _pointer;
  bool _saved = false;
  bool _allowPop = false;
  SaveFailureReason? _saveFailure;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    if (widget.photo.path.isNotEmpty) {
      File(widget.photo.path).delete().ignore();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _loadFailed = false;
    });
    try {
      final source = await _processor.normalize(
        await widget.photo.readAsBytes(),
      );
      if (!mounted) return;
      setState(() => _source = source);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _loadError =
              error is PhotoProcessingException &&
                  error.reason == PhotoProcessingFailure.imageTooLarge
              ? '写真のサイズが対応上限を超えています。解像度を下げて撮り直してください。'
              : '写真を読み込めませんでした。撮り直すか再試行してください。';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retake() async {
    if (_busy) return;
    if (_regions.isNotEmpty && !_saved) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('編集を破棄しますか？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('編集を続ける'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('破棄する'),
            ),
          ],
        ),
      );
      if (discard != true || !mounted) return;
    }
    setState(() => _allowPop = true);
    await Future<void>.delayed(Duration.zero);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _prepare() async {
    final source = _source;
    if (_busy || source == null) return;
    setState(() {
      _busy = true;
      _processingFailed = false;
      _pointer = null;
      _start = null;
      _drag = null;
    });
    try {
      final jpeg = await _processor.redact(source, List.of(_regions));
      if (mounted) setState(() => _preview = jpeg);
    } catch (_) {
      if (mounted) setState(() => _processingFailed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final jpeg = _preview;
    if (_busy || jpeg == null || _saved) return;
    setState(() {
      _busy = true;
      _saveFailure = null;
    });
    SaveResult result;
    try {
      result = await _saver.save(jpeg);
    } catch (_) {
      result = const SaveFailed(SaveFailureReason.failed);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _saved = result is SaveSucceeded;
      if (result case SaveFailed(:final reason)) _saveFailure = reason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final preview = _preview;
    return PopScope(
      canPop: !_busy && (_allowPop || _regions.isEmpty || _saved),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _retake();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: source == null
                    ? Center(
                        child: _loadFailed
                            ? Text(_loadError)
                            : const CircularProgressIndicator(),
                      )
                    : preview != null
                    ? Image.memory(
                        preview.bytes,
                        fit: BoxFit.contain,
                        semanticLabel: '保存する加工済み写真',
                      )
                    : _editor(source),
              ),
              Flexible(
                flex: 0,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_busy) const LinearProgressIndicator(),
                      if (_saved) ...[
                        const Text('写真を保存しました', textAlign: TextAlign.center),
                        FilledButton(
                          onPressed: _retake,
                          child: const Text('もう一枚'),
                        ),
                      ] else if (preview != null) ...[
                        const Text('隠し忘れがないか確認してください。安全を完全に保証するものではありません。'),
                        if (_saveFailure != null)
                          Text(
                            _saveFailure == SaveFailureReason.permissionDenied
                                ? '保存が許可されていません。設定から許可して再試行してください。'
                                : '保存できませんでした。空き容量を確認して再試行してください。',
                          ),
                        if (_saveFailure == SaveFailureReason.permissionDenied)
                          TextButton(
                            onPressed: _busy ? null : _openSettings,
                            child: const Text('設定を開く'),
                          ),
                        FilledButton(
                          onPressed: _busy ? null : _save,
                          child: const Text('写真に保存'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _preview = null;
                                  _saveFailure = null;
                                }),
                          child: const Text('編集へ戻る'),
                        ),
                      ] else ...[
                        if (_processingFailed)
                          const Text('画像を加工できませんでした。選択を保持しています。もう一度お試しください。'),
                        Text(
                          '${_regions.length}箇所の領域を選択中',
                          textAlign: TextAlign.center,
                        ),
                        const Text(
                          '画像上をドラッグして黒塗り範囲を選択してください',
                          textAlign: TextAlign.center,
                        ),
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton(
                              onPressed: _busy || _regions.isEmpty
                                  ? null
                                  : () => setState(() {
                                      _regions.removeLast();
                                      _drag = null;
                                      _start = null;
                                    }),
                              child: const Text('取り消す'),
                            ),
                            TextButton(
                              onPressed: _busy || _regions.isEmpty
                                  ? null
                                  : () => setState(() {
                                      _regions.clear();
                                      _drag = null;
                                      _start = null;
                                    }),
                              child: const Text('すべてリセット'),
                            ),
                          ],
                        ),
                        FilledButton(
                          onPressed: _busy || source == null ? null : _prepare,
                          child: const Text('保存前に確認'),
                        ),
                        if (_loadFailed)
                          TextButton(
                            onPressed: _busy ? null : _load,
                            child: const Text('再試行'),
                          ),
                        TextButton(
                          onPressed: _busy ? null : _retake,
                          child: const Text('撮り直す'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    try {
      await const MethodChannel('dev.camereon/app_settings')
          .invokeMethod<void>('open');
    } catch (_) {
      // 権限エラーと編集状態を残し、再試行できるようにする。
    }
  }

  Widget _editor(SourcePhoto source) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = math.min(
        constraints.maxWidth / source.width,
        constraints.maxHeight / source.height,
      );
      final size = Size(source.width * scale, source.height * scale);
      final rect = Alignment.center.inscribe(
        size,
        Offset.zero & constraints.biggest,
      );
      Offset pixel(Offset point) => (point - rect.topLeft) / scale;
      return Listener(
        key: const ValueKey('photo-canvas'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          if (_busy ||
              _pointer != null ||
              !rect.contains(event.localPosition)) {
            return;
          }
          setState(() {
            _pointer = event.pointer;
            _start = pixel(event.localPosition);
            _drag = null;
          });
        },
        onPointerMove: (event) {
          final start = _start;
          if (_busy || _pointer != event.pointer || start == null) return;
          setState(
            () => _drag = HideRegion.fromRect(
              Rect.fromPoints(start, pixel(event.localPosition)),
              imageWidth: source.width,
              imageHeight: source.height,
            ),
          );
        },
        onPointerUp: (event) {
          if (_pointer != event.pointer) return;
          setState(() {
            if (_drag != null && !_busy) _regions.add(_drag!);
            _pointer = null;
            _drag = null;
            _start = null;
          });
        },
        onPointerCancel: (event) {
          if (_pointer != event.pointer) return;
          setState(() {
            _pointer = null;
            _drag = null;
            _start = null;
          });
        },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: rect,
              child: Image.memory(
                source.bytes,
                fit: BoxFit.fill,
                semanticLabel: '撮影した写真',
              ),
            ),
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: SelectionPainter(
                    regions: List.unmodifiable([..._regions, ?_drag]),
                    imageWidth: source.width,
                    imageHeight: source.height,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.regions,
    required this.imageWidth,
    required this.imageHeight,
  });
  final List<HideRegion> regions;
  final int imageWidth;
  final int imageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / imageWidth, size.height / imageHeight);
    final paint = Paint()..color = Colors.black;
    for (final region in regions) {
      canvas.drawRect(region.toRect(), paint);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) =>
      oldDelegate.imageWidth != imageWidth ||
      oldDelegate.imageHeight != imageHeight ||
      oldDelegate.regions != regions;
}
