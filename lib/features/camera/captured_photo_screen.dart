import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/analysis/face_detection.dart';
import '../../core/analysis/infrastructure/mlkit_face_detector.dart';
import '../../core/detection/android_text_region_detector.dart';
import '../../core/detection/android_object_region_detector.dart';
import '../../core/detection/region_detector.dart';
import '../../core/photo/android_photo_saver.dart';
import '../../core/photo/hide_region.dart';
import '../../core/photo/flutter_photo_processor.dart';
import '../../core/photo/photo_images.dart';
import '../../core/photo/photo_processor.dart';
import '../../core/photo/photo_processing_exception.dart';
import '../../core/photo/photo_saver.dart';
import '../analysis/face_detection_controller.dart';
import '../analysis/photo_analysis_entry.dart';
import '../detection/candidate_overlay.dart';
import 'glass_photo_chrome.dart';

/// Automatic detection; the photograph's frames are the editing controls.
class CapturedPhotoScreen extends StatefulWidget {
  const CapturedPhotoScreen({
    super.key,
    required this.photo,
    this.onSourceLoaded,
    this.processor,
    this.saver,
    this.faceDetector,
    this.detector,
    this.objectDetector,
  });
  final XFile photo;
  final ValueChanged<SourcePhoto>? onSourceLoaded;
  final PhotoProcessor? processor;
  final PhotoSaver? saver;
  final PhotoFaceDetector? faceDetector;
  final RegionDetector? detector;
  final RegionDetector? objectDetector;
  @override
  State<CapturedPhotoScreen> createState() => _CapturedPhotoScreenState();
}

class _CapturedPhotoScreenState extends State<CapturedPhotoScreen>
    with WidgetsBindingObserver {
  late final PhotoProcessor _processor =
      widget.processor ?? FlutterPhotoProcessor();
  late final PhotoSaver _saver = widget.saver ?? AndroidPhotoSaver();
  late final RegionDetector _detector =
      widget.detector ?? AndroidTextRegionDetector();
  late final RegionDetector _objectDetector =
      widget.objectDetector ?? AndroidObjectRegionDetector();
  late final _faces = FaceDetectionController(
    widget.faceDetector ?? MlKitFaceDetector(),
  );
  final Map<String, RegionCandidate> _faceCandidates = {};
  List<RegionCandidate> _candidates = [];
  Set<RegionCandidate> _selected = {};
  final List<Set<RegionCandidate>> _history = [];
  final Set<bool> _failedScans = {};
  bool _truncated = false;
  bool _detecting = false;
  int _detectionEpoch = 0;
  int _autoDetectionEpoch = 0;
  bool _automaticDetectionStarted = false;
  bool _facesOnly = false;
  List<RegionCandidate> get _visibleCandidates => [
    ..._faceCandidates.values,
    if (!_facesOnly) ..._candidates,
  ];
  List<HideRegion> get _redactions =>
      {for (final c in _selected) c.region}.toList();
  bool get _scanning =>
      _detecting || _faces.status == FaceDetectionStatus.detecting;
  bool get _canRetry =>
      !_scanning && (_failedScans.isNotEmpty || _faces.canRetry);
  SourcePhoto? _source;
  RedactedJpeg? _preview;
  bool _covered = false;
  bool _busy = true;
  bool _loadFailed = false;
  String _loadError = '写真を読み込めませんでした';
  bool _processingFailed = false;
  bool _saved = false;
  bool _allowPop = false;
  SaveFailureReason? _saveFailure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _faces.addListener(_faceChanged);
    _load();
  }

  void _faceChanged() {
    if (!mounted) return;
    setState(() {
      for (final face in _faces.candidates) {
        _faceCandidates.putIfAbsent(
          face.id,
          () => RegionCandidate(kind: CandidateKind.face, region: face.region),
        );
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _covered = AnalysisEntryVisibility.coveredOf(context);
    if (_covered) _faces.cancel();
    if (!_covered) scheduleMicrotask(_startAutomaticDetection);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _faces.cancel();
    if (state == AppLifecycleState.resumed) _startAutomaticDetection();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _faces.removeListener(_faceChanged);
    _faces.dispose();
    _detectionEpoch++;
    _autoDetectionEpoch++;
    if (widget.photo.path.isNotEmpty) File(widget.photo.path).delete().ignore();
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
      widget.onSourceLoaded?.call(source);
    } catch (error) {
      if (mounted) {
        setState(() {
          _loadFailed = true;
          _loadError =
              error is PhotoProcessingException &&
                  error.reason == PhotoProcessingFailure.imageTooLarge
              ? '写真のサイズが対応上限を超えています'
              : '写真を読み込めませんでした';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    _startAutomaticDetection();
  }

  void _startAutomaticDetection() {
    if (!mounted || _busy || _loadFailed || _automaticDetectionStarted) return;
    final source = _source;
    if (source == null || _preview != null) return;
    if (_covered ||
        (WidgetsBinding.instance.lifecycleState != null &&
            WidgetsBinding.instance.lifecycleState !=
                AppLifecycleState.resumed)) {
      _faces.markDeferred();
      return;
    }
    _automaticDetectionStarted = true;
    unawaited(_faces.detect(source));
    unawaited(_detectAll(source));
  }

  Future<void> _detectAll(SourcePhoto source) async {
    final epoch = ++_autoDetectionEpoch;
    // Keep the two ONNX models' peak allocations separate.
    await _detect();
    if (!mounted ||
        epoch != _autoDetectionEpoch ||
        !identical(source, _source) ||
        _preview != null) {
      return;
    }
    await _detect(objects: true);
  }

  Future<void> _detect({bool objects = false}) async {
    final source = _source;
    if (_busy || _detecting || source == null) return;
    final epoch = ++_detectionEpoch;
    setState(() {
      _detecting = true;
      _failedScans.remove(objects);
    });
    try {
      final result = await (objects ? _objectDetector : _detector).detect(
        source,
      );
      if (!mounted ||
          epoch != _detectionEpoch ||
          !identical(source, _source) ||
          _preview != null) {
        return;
      }
      setState(() {
        bool same(RegionCandidate a, RegionCandidate b) =>
            a.kind == b.kind && a.region == b.region;
        final previous = _candidates;
        final kinds = objects
            ? {CandidateKind.person, CandidateKind.screen}
            : {CandidateKind.text};
        _candidates = [
          for (final c in previous)
            if (!kinds.contains(c.kind) ||
                _selected.contains(c) ||
                _history.any((selection) => selection.contains(c)) ||
                result.candidates.any((next) => same(c, next)))
              c,
          for (final c in result.candidates)
            if (!previous.any((old) => same(c, old))) c,
        ];
        _truncated = _truncated || result.truncated;
      });
    } catch (_) {
      if (mounted && epoch == _detectionEpoch) {
        setState(() => _failedScans.add(objects));
      }
    } finally {
      if (mounted && epoch == _detectionEpoch) {
        setState(() => _detecting = false);
      }
    }
  }

  void _retry() {
    final source = _source;
    if (_busy || _covered || !_canRetry || source == null) return;
    if (_faces.canRetry) unawaited(_faces.detect(source));
    unawaited(_detectAll(source));
  }

  void _toggle(RegionCandidate candidate) {
    if (_busy || _preview != null) return;
    setState(() {
      _history.add(Set.of(_selected));
      if (!_selected.remove(candidate)) _selected.add(candidate);
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _undo() {
    if (_busy || _history.isEmpty) return;
    setState(() => _selected = _history.removeLast());
    unawaited(HapticFeedback.selectionClick());
  }

  Future<void> _retake() async {
    if (_busy) return;
    if (_redactions.isNotEmpty && !_saved) {
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
    _faces.cancel();
    _autoDetectionEpoch++;
    _detectionEpoch++;
    setState(() => _allowPop = true);
    await Future<void>.delayed(Duration.zero);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _prepare() async {
    final source = _source;
    if (_busy || source == null) return;
    _faces.cancel();
    setState(() {
      // Returning from confirmation must still offer a way to finish a scan.
      if (_detecting) _failedScans.addAll({false, true});
      _detectionEpoch++;
      _autoDetectionEpoch++;
      _detecting = false;
      _busy = true;
      _processingFailed = false;
    });
    try {
      final jpeg = await _processor.redact(source, List.of(_redactions));
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

  String get _status {
    if (_loadFailed) return '写真を開けませんでした';
    if (_saved) return '保存しました';
    if (_busy) return _source == null ? '写真を準備中' : '仕上げています';
    if (_preview != null) return '保存前に確認';
    if (_scanning) return '検出中';
    if (_canRetry) return '一部を検出できませんでした';
    if (_selected.isNotEmpty) return '${_selected.length}件を選択';
    return _visibleCandidates.isEmpty
        ? '候補が見つかりませんでした'
        : '${_visibleCandidates.length}件の候補';
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    final preview = _preview;
    return PopScope(
      canPop: !_busy && (_allowPop || _redactions.isEmpty || _saved),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _retake();
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF070A0D),
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (source != null)
              IgnorePointer(
                child: RepaintBoundary(
                  child: Opacity(
                    opacity: .22,
                    child: ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: 44, sigmaY: 44),
                      child: Image.memory(
                        source.bytes,
                        fit: BoxFit.cover,
                        excludeFromSemantics: true,
                      ),
                    ),
                  ),
                ),
              ),
            SafeArea(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (source == null)
                    _loading()
                  else if (preview != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 84, 12, 124),
                      child: Image.memory(
                        preview.bytes,
                        fit: BoxFit.contain,
                        semanticLabel: '保存する加工済み写真',
                      ),
                    )
                  else
                    _editor(source),
                  Positioned(
                    top: 16,
                    left: 16,
                    child: PhotoGlass(
                      child: GlassIconButton(
                        label: '撮り直す',
                        icon: Icons.close_rounded,
                        onPressed: _busy ? null : _retake,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 20,
                    left: 78,
                    right: 20,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: PhotoGlass(
                        child: InkWell(
                          onTap: _canRetry && preview == null ? _retry : null,
                          borderRadius: BorderRadius.circular(32),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                AnimatedContainer(
                                  duration: const Duration(milliseconds: 240),
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: _canRetry
                                        ? const Color(0xFFFFCB8A)
                                        : glassMint,
                                    boxShadow: [
                                      BoxShadow(
                                        color: glassMint.withValues(alpha: .5),
                                        blurRadius: 10,
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 9),
                                Flexible(
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 220),
                                    child: Text(
                                      _status,
                                      key: ValueKey(_status),
                                      maxLines: 2,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                ),
                                if (_canRetry && preview == null) ...[
                                  const SizedBox(width: 8),
                                  const Icon(
                                    Icons.refresh_rounded,
                                    size: 16,
                                    color: Colors.white,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (source != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _hint(),
                              const SizedBox(height: 14),
                              _dock(),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loading() => Center(
    child: _loadFailed
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_loadError, style: const TextStyle(color: Colors.white70)),
              const SizedBox(height: 12),
              TextButton(
                onPressed: _busy ? null : _load,
                child: const Text('再試行'),
              ),
            ],
          )
        : const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: glassMint,
            ),
          ),
  );

  Widget _hint() {
    final text = _saveFailure == SaveFailureReason.permissionDenied
        ? '保存の許可を設定から確認してください'
        : _saveFailure != null
        ? '保存できませんでした。もう一度お試しください'
        : _processingFailed
        ? '加工できませんでした。選択は保持しています'
        : _saved
        ? '写真を保存しました'
        : _preview != null
        ? '隠し忘れがないか確認してください'
        : _canRetry
        ? '上のステータスをタップして再試行'
        : _truncated
        ? '一部の候補を表示しています'
        : _facesOnly && _selected.any((c) => c.kind != CandidateKind.face)
        ? '顔の候補のみ表示 · 適用済みの黒塗りは保持'
        : _scanning
        ? '写真の中から、隠せる場所を探しています'
        : _visibleCandidates.isEmpty
        ? '別の写真で試してください'
        : _selected.isEmpty
        ? '枠をタップして隠す'
        : 'もう一度タップで解除';
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 220),
      child: Text(
        text,
        key: ValueKey(text),
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white70,
          fontSize: 12,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _filter(String label, bool facesOnly) => Expanded(
    child: Semantics(
      selected: _facesOnly == facesOnly,
      child: InkWell(
        onTap: _busy ? null : () => setState(() => _facesOnly = facesOnly),
        borderRadius: BorderRadius.circular(24),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            color: _facesOnly == facesOnly
                ? Colors.white.withValues(alpha: .15)
                : Colors.transparent,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: _facesOnly == facesOnly ? Colors.white : Colors.white54,
            ),
          ),
        ),
      ),
    ),
  );

  Widget _dock() => PhotoGlass(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: _saved
          ? Center(
              child: TextButton.icon(
                onPressed: _busy ? null : _retake,
                icon: const Icon(Icons.check_rounded, color: glassMint),
                label: const Text(
                  'もう一枚',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            )
          : _preview != null
          ? Row(
              children: [
                GlassIconButton(
                  label: '編集へ戻る',
                  icon: Icons.arrow_back_rounded,
                  onPressed: _busy
                      ? null
                      : () => setState(() {
                          _preview = null;
                          _saveFailure = null;
                        }),
                ),
                const Spacer(),
                if (_saveFailure == SaveFailureReason.permissionDenied)
                  TextButton(
                    onPressed: _busy ? null : _openSettings,
                    child: const Text('設定を開く'),
                  ),
                TextButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: const Icon(Icons.download_rounded, color: glassMint),
                  label: const Text(
                    '写真に保存',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
              ],
            )
          : Row(
              children: [
                _filter('すべて', false),
                _filter('顔だけ', true),
                const SizedBox(width: 4),
                Container(width: 1, height: 20, color: Colors.white12),
                const SizedBox(width: 4),
                GlassIconButton(
                  label: '取り消す',
                  icon: Icons.undo_rounded,
                  onPressed: _busy || _history.isEmpty ? null : _undo,
                ),
                const SizedBox(width: 4),
                GlassIconButton(
                  label: '保存前に確認',
                  icon: Icons.arrow_forward_rounded,
                  primary: true,
                  onPressed: _busy ? null : _prepare,
                ),
              ],
            ),
    ),
  );

  Future<void> _openSettings() async {
    try {
      await const MethodChannel('dev.camereon/app_settings')
          .invokeMethod<void>('open');
    } catch (_) {
      /* Keep the edited image and allow another save attempt. */
    }
  }

  void _tapCandidate(Offset point, double scale) {
    final tolerance = 8 / scale;
    final hits = _visibleCandidates
        .where((c) => c.region.toRect().inflate(tolerance).contains(point))
        .toList();
    double edgeDistance(RegionCandidate c) {
      final r = c.region.toRect();
      return [
        (point.dx - r.left).abs(),
        (point.dx - r.right).abs(),
        (point.dy - r.top).abs(),
        (point.dy - r.bottom).abs(),
      ].reduce(math.min);
    }

    hits.sort((a, b) {
      final aEdge = edgeDistance(a) <= tolerance;
      final bEdge = edgeDistance(b) <= tolerance;
      if (aEdge != bEdge) return aEdge ? -1 : 1;
      return (a.region.width * a.region.height).compareTo(
        b.region.width * b.region.height,
      );
    });
    if (hits.isEmpty) return;
    final coincident = hits
        .where((c) => c.region == hits.first.region)
        .toList();
    if (coincident.length == 1) {
      _toggle(hits.first);
      return;
    }
    // Identical boxes remain independently selectable without a permanent list.
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: PhotoGlass(
            radius: 28,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final c in coincident)
                  ListTile(
                    title: Text(
                      '${c.kind.label}を${_selected.contains(c) ? '表示する' : '隠す'}',
                      style: const TextStyle(color: Colors.white),
                    ),
                    trailing: Icon(
                      _selected.contains(c)
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      color: glassMint,
                    ),
                    onTap: () {
                      _toggle(c);
                      Navigator.pop(context);
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _editor(SourcePhoto source) => LayoutBuilder(
    builder: (context, constraints) {
      final available = Size(
        math.max(1, constraints.maxWidth - 24),
        math.max(1, constraints.maxHeight - 208),
      );
      final scale = math.min(
        available.width / source.width,
        available.height / source.height,
      );
      final rect = Alignment.center.inscribe(
        Size(source.width * scale, source.height * scale),
        Rect.fromLTWH(12, 84, available.width, available.height),
      );
      return GestureDetector(
        key: const ValueKey('photo-canvas'),
        behavior: HitTestBehavior.opaque,
        onTapUp: _busy
            ? null
            : (event) {
                if (rect.contains(event.localPosition)) {
                  _tapCandidate(
                    (event.localPosition - rect.topLeft) / scale,
                    scale,
                  );
                }
              },
        child: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fromRect(
              rect: rect,
              child: RepaintBoundary(
                child: Image.memory(
                  source.bytes,
                  fit: BoxFit.fill,
                  semanticLabel: '撮影した写真',
                ),
              ),
            ),
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: CustomPaint(
                  painter: SelectionPainter(
                    regions: List.unmodifiable(_redactions),
                    imageWidth: source.width,
                    imageHeight: source.height,
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: rect,
              child: RepaintBoundary(
                child: CandidateOverlay(
                  candidates: _visibleCandidates,
                  selectedCandidates: Set.unmodifiable(_selected),
                  imageWidth: source.width,
                  imageHeight: source.height,
                  onToggle: _busy ? null : _toggle,
                ),
              ),
            ),
            Positioned.fromRect(
              rect: rect,
              child: RepaintBoundary(
                child: PhotoScanEffect(active: _scanning && !_covered),
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
