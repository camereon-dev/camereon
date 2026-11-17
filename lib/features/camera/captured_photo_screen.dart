import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/analysis/face_detection.dart';
import '../../core/analysis/infrastructure/mlkit_face_detector.dart';
import '../../core/detection/android_text_region_detector.dart';
import '../../core/detection/android_object_region_detector.dart';
import '../../core/detection/region_detector.dart';
import '../../core/detection/japanese_address_detector.dart';
import '../../core/photo/android_photo_saver.dart';
import '../../core/photo/hide_region.dart';
import '../../core/photo/flutter_photo_processor.dart';
import '../../core/photo/frosted_preview.dart';
import '../../core/photo/photo_images.dart';
import '../../core/photo/photo_processor.dart';
import '../../core/photo/photo_processing_exception.dart';
import '../../core/photo/photo_saver.dart';
import '../../core/photo/photo_sharer.dart';
import '../analysis/face_detection_controller.dart';
import '../analysis/photo_analysis_entry.dart';
import '../detection/candidate_overlay.dart';
import 'glass_photo_chrome.dart';

/// Longest side of the editor's decoded photo texture.
const displayDecodeSide = 4096;

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
    this.previewer,
    this.initialCandidates,
    this.addressDetector,
    this.includeOtherCandidates = false,
    this.startWithConfirmation = false,
    this.sharer,
  });

  /// Captures first show the automatically redacted result before editing.
  final bool startWithConfirmation;
  final XFile photo;
  final ValueChanged<SourcePhoto>? onSourceLoaded;
  final PhotoProcessor? processor;
  final PhotoSaver? saver;
  final PhotoFaceDetector? faceDetector;
  final RegionDetector? detector;
  final RegionDetector? objectDetector;
  final RegionDetector? addressDetector;

  /// Legacy multi-kind editor is retained only for detector evaluation.
  final bool includeOtherCandidates;

  /// Trusted candidates in normalized photo coordinates, hidden before display.
  /// Called once after loading; user choices are never reset by detection.
  final List<RegionCandidate> Function(SourcePhoto)? initialCandidates;

  /// Builds the frosted preview of selected areas; tests pass [FrostedPreviewer.none].
  final FrostedPreviewer? previewer;
  final PhotoSharer? sharer;
  @override
  State<CapturedPhotoScreen> createState() => _CapturedPhotoScreenState();
}

class _CapturedPhotoScreenState extends State<CapturedPhotoScreen>
    with WidgetsBindingObserver {
  late final PhotoProcessor _processor =
      widget.processor ?? FlutterPhotoProcessor();
  late final PhotoSaver _saver = widget.saver ?? AndroidPhotoSaver();
  late final PhotoSharer _sharer = widget.sharer ?? PlatformPhotoSharer();
  late final RegionDetector _detector =
      widget.detector ?? AndroidTextRegionDetector();
  late final RegionDetector _addressDetector =
      widget.addressDetector ?? JapaneseAddressDetector();
  bool _addressDetecting = false;
  bool _addressFailed = false;
  final Set<HideRegion> _seenAddresses = {};
  late final RegionDetector _objectDetector =
      widget.objectDetector ?? AndroidObjectRegionDetector();
  late final _faces = FaceDetectionController(
    widget.faceDetector ?? MlKitFaceDetector(),
  );
  late final FrostedPreviewer _previewer =
      widget.previewer ?? FrostedPreviewer();
  // Frosted textures per selected region; drawn as-is while zooming.
  final Map<HideRegion, FrostedPatch> _patches = {};
  final Set<HideRegion> _pendingPatches = {};
  Timer? _patchTimer;
  // Long-press stroke: the first frame decides whether it selects or clears.
  bool? _strokeSelects;
  final Set<RegionCandidate> _stroked = {};
  final Map<String, RegionCandidate> _faceCandidates = {};
  List<RegionCandidate> _candidates = [];
  Set<RegionCandidate> _selected = {};
  final List<Set<RegionCandidate>> _history = [];
  final _photoTransform = TransformationController();
  // The confirmation image zooms on its own, starting from the whole photo.
  final _previewTransform = TransformationController();
  Offset _previewTapPoint = Offset.zero;
  final Set<bool> _failedScans = {};
  bool _truncated = false;
  bool _detecting = false;
  int _detectionEpoch = 0;
  int _autoDetectionEpoch = 0;
  bool _automaticDetectionStarted = false;
  List<RegionCandidate> get _visibleCandidates => [
    ..._faceCandidates.values,
    for (final c in _candidates)
      if (_selected.contains(c) ||
          (!_coveredByFace(c) && !_coveredByAddress(c)))
        c,
  ];

  // OCR can return smaller text frames inside a known address. Keep a single
  // tap target there, even after the address has been revealed.
  bool _coveredByAddress(RegionCandidate candidate) {
    if (candidate.kind != CandidateKind.text) return false;
    final rect = candidate.region.toRect();
    return _candidates.where((c) => c.kind == CandidateKind.address).any((c) {
      final overlap = rect.intersect(c.region.toRect());
      return overlap.width > 0 &&
          overlap.height > 0 &&
          overlap.width * overlap.height >= rect.width * rect.height * .7;
    });
  }

  /// The text detector fires on eyes, glasses and scarf edges. A text frame
  /// well inside a face, or a frame enclosing most of a face it does not
  /// otherwise need, is hidden; a coincident frame stays selectable by kind.
  bool _coveredByFace(RegionCandidate c) {
    if (c.kind != CandidateKind.text) return false;
    final r = c.region.toRect();
    final textArea = r.width * r.height;
    return _faceCandidates.values.any((face) {
      final f = face.region.toRect();
      final i = r.intersect(f);
      if (i.width <= 0 || i.height <= 0) return false;
      final shared = i.width * i.height;
      final faceArea = f.width * f.height;
      final inside = shared >= textArea * .7 && textArea < faceArea * .9;
      final enclosing =
          shared >= faceArea * .7 &&
          textArea > faceArea * 1.1 &&
          faceArea >= textArea * .25;
      return inside || enclosing;
    });
  }

  List<HideRegion> get _redactions =>
      {for (final c in _selected) c.region}.toList();
  bool get _scanning =>
      _addressDetecting ||
      _detecting ||
      _faces.status == FaceDetectionStatus.detecting;
  bool get _canRetry =>
      !_scanning &&
      (_addressFailed || _failedScans.isNotEmpty || _faces.canRetry);
  SourcePhoto? _source;
  RedactedJpeg? _preview;
  late bool _waitingForConfirmation = widget.startWithConfirmation;
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
        _faceCandidates.putIfAbsent(face.id, () {
          final candidate = RegionCandidate(
            kind: CandidateKind.face,
            region: face.region,
          );
          if (!widget.includeOtherCandidates) {
            _selected.add(candidate);
            for (final previous in _history) {
              previous.add(candidate);
            }
          }
          return candidate;
        });
      }
    });
    _schedulePatches();
    scheduleMicrotask(_maybePrepareInitialConfirmation);
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
    _photoTransform.dispose();
    _previewTransform.dispose();
    _patchTimer?.cancel();
    for (final patch in _patches.values) {
      patch.dispose();
    }
    _previewer.dispose();
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
      final initial =
          (widget.initialCandidates?.call(source) ?? const <RegionCandidate>[])
              .where(
                (c) =>
                    widget.includeOtherCandidates ||
                    c.kind == CandidateKind.address,
              )
              .toList();
      setState(() {
        _source = source;
        _candidates = List.of(initial);
        _selected = initial.toSet();
        _history.clear();
        _seenAddresses.addAll(initial.map((c) => c.region));
      });
      widget.onSourceLoaded?.call(source);
      unawaited(_previewer.load(source).then((_) => _refreshPatches()));
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
    if (!widget.includeOtherCandidates) {
      unawaited(_detectAddresses(source));
      return;
    }
    unawaited(_detectAll(source));
  }

  Future<void> _detectAll(SourcePhoto source) async {
    final epoch = ++_autoDetectionEpoch;
    // Keep the two ONNX models' peak allocations separate. The quick object
    // pass shows people, screens and vehicles before the longer text tiles.
    await _detect(objects: true);
    if (!mounted ||
        epoch != _autoDetectionEpoch ||
        !identical(source, _source) ||
        _preview != null) {
      return;
    }
    await _detect();
  }

  Future<void> _detectAddresses(SourcePhoto source) async {
    if (_busy || _addressDetecting) return;
    final epoch = ++_detectionEpoch;
    setState(() {
      _addressDetecting = true;
      _addressFailed = false;
    });
    try {
      final result = await _addressDetector.detect(source);
      if (!mounted || epoch != _detectionEpoch || _preview != null) return;
      setState(() {
        for (final c in result.candidates) {
          if (c.kind != CandidateKind.address || _knownAddress(c.region)) {
            continue;
          }
          _seenAddresses.add(c.region);
          _candidates.add(c);
          _selected.add(c);
          // Automatic discovery isn't an undo step. Earlier user actions must
          // not accidentally reveal addresses discovered after those actions.
          for (final previous in _history) {
            previous.add(c);
          }
        }
        _addressFailed = result.partial;
        _truncated = _truncated || result.truncated;
      });
      _schedulePatches();
    } catch (_) {
      if (mounted && epoch == _detectionEpoch) {
        setState(() => _addressFailed = true);
      }
    } finally {
      if (mounted && epoch == _detectionEpoch) {
        setState(() => _addressDetecting = false);
        scheduleMicrotask(_maybePrepareInitialConfirmation);
      }
    }
  }

  bool _knownAddress(HideRegion region) => _seenAddresses.any((old) {
    final a = old.toRect();
    final b = region.toRect();
    final overlap = a.intersect(b);
    final area = overlap.width > 0 && overlap.height > 0
        ? overlap.width * overlap.height
        : 0;
    return area >= a.width * a.height * .7 && area >= b.width * b.height * .7;
  });

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
            ? {
                CandidateKind.person,
                CandidateKind.screen,
                CandidateKind.vehicle,
              }
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
        if (result.partial) _failedScans.add(objects);
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
    if (!widget.includeOtherCandidates) {
      unawaited(_detectAddresses(source));
      return;
    }
    unawaited(_detectAll(source));
  }

  void _toggle(RegionCandidate candidate) {
    if (_busy || _preview != null) return;
    final next = Set.of(_selected);
    if (!next.remove(candidate)) next.add(candidate);
    _select(next);
  }

  /// One undo step per change, however many frames it touched.
  void _select(Set<RegionCandidate> next) {
    if (setEquals(next, _selected)) return;
    setState(() {
      _history.add(Set.of(_selected));
      _selected = next;
    });
    unawaited(HapticFeedback.selectionClick());
    _schedulePatches();
  }

  /// Hide every frame of one kind, or show them all again when all are hidden.
  void _toggleKind(CandidateKind? kind) {
    if (_busy || _preview != null) return;
    final frames = _visibleCandidates
        .where((c) => kind == null || c.kind == kind)
        .toSet();
    if (frames.isEmpty) return;
    final allHidden = frames.every(_selected.contains);
    _select(allHidden ? _selected.difference(frames) : _selected.union(frames));
  }

  void _undo() {
    if (_busy || _history.isEmpty) return;
    setState(() => _selected = _history.removeLast());
    unawaited(HapticFeedback.selectionClick());
    _schedulePatches();
  }

  // Long press, then drag across frames: paint them hidden (or shown) in one
  // undo step. A plain drag still pans the zoomed photo.
  void _strokeStart(Offset point, double scale) {
    if (_busy || _preview != null) return;
    _stroked.clear();
    final hit = _hitCandidate(point, scale);
    _strokeSelects = hit == null ? true : !_selected.contains(hit);
    if (hit != null) _strokeOver(hit);
    unawaited(HapticFeedback.mediumImpact());
  }

  void _strokeMove(Offset point, double scale) {
    final hit = _hitCandidate(point, scale);
    if (hit != null) _strokeOver(hit);
  }

  void _strokeOver(RegionCandidate candidate) {
    final selects = _strokeSelects;
    if (selects == null || !_stroked.add(candidate)) return;
    if (_selected.contains(candidate) == selects) return;
    setState(() {
      if (_stroked.length == 1) _history.add(Set.of(_selected));
      final next = Set.of(_selected);
      if (selects) {
        next.add(candidate);
      } else {
        next.remove(candidate);
      }
      _selected = next;
    });
    unawaited(HapticFeedback.selectionClick());
  }

  void _strokeEnd() {
    _strokeSelects = null;
    _stroked.clear();
    _schedulePatches();
  }

  void _schedulePatches() {
    _patchTimer?.cancel();
    _patchTimer = Timer(const Duration(milliseconds: 120), _refreshPatches);
  }

  /// Keep one frosted texture per selected region, computed off the UI thread.
  Future<void> _refreshPatches() async {
    if (!mounted) return;
    final wanted = {for (final c in _selected) c.region};
    final stale = _patches.keys.where((r) => !wanted.contains(r)).toList();
    if (stale.isNotEmpty) {
      setState(() {
        for (final region in stale) {
          _patches.remove(region)?.dispose();
        }
      });
    }
    for (final region in wanted) {
      if (_patches.containsKey(region) || !_pendingPatches.add(region)) {
        continue;
      }
      unawaited(
        _previewer.patch(region).then((patch) {
          _pendingPatches.remove(region);
          if (patch == null) return;
          if (!mounted || !_selected.any((c) => c.region == region)) {
            patch.dispose();
            return;
          }
          setState(() => _patches[region] = patch);
        }),
      );
    }
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

  void _maybePrepareInitialConfirmation() {
    if (!mounted ||
        !_waitingForConfirmation ||
        !_automaticDetectionStarted ||
        _busy ||
        _scanning ||
        _canRetry ||
        _processingFailed ||
        _covered ||
        _source == null ||
        _preview != null) {
      return;
    }
    unawaited(_prepare());
  }

  void _openEditor() {
    setState(() {
      _waitingForConfirmation = false;
      _preview = null;
      _saveFailure = null;
    });
  }

  Future<void> _prepare() async {
    final source = _source;
    if (_busy ||
        source == null ||
        (!widget.includeOtherCandidates && _scanning)) {
      return;
    }
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
      if (mounted) {
        _previewTransform.value = Matrix4.identity();
        setState(() {
          _preview = jpeg;
          _waitingForConfirmation = false;
        });
      }
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
                      // Heavily blurred: a small decode is indistinguishable.
                      child: Image.memory(
                        source.bytes,
                        fit: BoxFit.cover,
                        cacheWidth: 512,
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
                    // Pinch to check the hidden areas up close; double-tap
                    // zooms in on that spot and back out.
                    GestureDetector(
                      onDoubleTapDown: (details) =>
                          _previewTapPoint = details.localPosition,
                      onDoubleTap: _togglePreviewZoom,
                      child: InteractiveViewer(
                        transformationController: _previewTransform,
                        minScale: 1,
                        maxScale: 8,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(12, 84, 12, 124),
                          child: Image.memory(
                            preview.bytes,
                            fit: BoxFit.contain,
                            semanticLabel: '保存する加工済み写真',
                          ),
                        ),
                      ),
                    )
                  else if (_waitingForConfirmation)
                    Center(
                      child: _canRetry || _processingFailed
                          ? const Text(
                              '確認用の写真を準備できませんでした',
                              style: TextStyle(color: Colors.white70),
                            )
                          : const CircularProgressIndicator(color: glassMint),
                    )
                  else
                    InteractiveViewer(
                      transformationController: _photoTransform,
                      minScale: 1,
                      maxScale: 8,
                      child: _editor(source),
                    ),
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
        : _scanning
        ? (widget.includeOtherCandidates
              ? '写真の中から、隠せる場所を探しています'
              : '写真の中から住所と顔を探しています')
        : _visibleCandidates.isEmpty
        ? (widget.includeOtherCandidates
              ? '別の写真で試してください'
              : '住所・顔の候補がありません。別の写真で試してください')
        : _selected.isEmpty
        ? '枠をタップ · 長押しでなぞって選択 · ピンチで拡大'
        : widget.includeOtherCandidates
        ? 'もう一度タップで解除 · 下のボタンで種類ごとに切替'
        : 'もう一度タップで解除 · 「住所」「顔」で一括切替';
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

  /// One tap hides every frame of a kind (or all of them); tap again to show.
  Widget _kindChips() {
    final counts = <CandidateKind?, (int, int)>{};
    final visible = _visibleCandidates;
    counts[null] = (visible.length, visible.where(_selected.contains).length);
    for (final kind in CandidateKind.values) {
      final frames = visible.where((c) => c.kind == kind);
      if (frames.isNotEmpty) {
        counts[kind] = (frames.length, frames.where(_selected.contains).length);
      }
    }
    if (visible.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 12),
        child: Text(
          '候補なし',
          style: TextStyle(color: Colors.white54, fontSize: 13),
        ),
      );
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          for (final entry in counts.entries)
            if (entry.key != null || counts.length > 2)
              _kindChip(entry.key, entry.value.$1, entry.value.$2),
        ],
      ),
    );
  }

  Widget _kindChip(CandidateKind? kind, int total, int hidden) {
    final all = hidden == total;
    final label = kind == null ? 'すべて' : kind.label;
    return Padding(
      key: ValueKey('kind-chip-${kind?.name ?? 'all'}'),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        button: true,
        toggled: all,
        label: '$labelを${all ? '表示' : '隠す'}',
        child: InkWell(
          onTap: _busy ? null : () => _toggleKind(kind),
          borderRadius: BorderRadius.circular(24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            constraints: const BoxConstraints(minHeight: 44),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              color: all
                  ? glassMint.withValues(alpha: .9)
                  : hidden > 0
                  ? glassMint.withValues(alpha: .18)
                  : Colors.white.withValues(alpha: .08),
              border: Border.all(
                color: all
                    ? Colors.transparent
                    : Colors.white.withValues(alpha: .18),
              ),
            ),
            child: Text(
              hidden > 0 && !all ? '$label $hidden/$total' : '$label $total',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: all ? const Color(0xFF142A25) : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dock() => PhotoGlass(
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: _saved
          ? Row(
              children: [
                Expanded(
                  child: _savedAction(
                    '共有',
                    Icons.ios_share_rounded,
                    _share,
                    primary: true,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _savedAction(
                    '開く',
                    Icons.photo_library_outlined,
                    _open,
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: _savedAction(
                    'もう一枚',
                    Icons.photo_camera_outlined,
                    _retake,
                  ),
                ),
              ],
            )
          : _preview != null
          ? Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              children: [
                Tooltip(
                  message: widget.startWithConfirmation ? '編集する' : '編集へ戻る',
                  child: TextButton.icon(
                    onPressed: _busy ? null : _openEditor,
                    icon: const Icon(Icons.edit_outlined, color: Colors.white),
                    label: const Text(
                      '編集する',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                ),
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
              ],
            )
          : _waitingForConfirmation
          ? Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: _busy || _scanning ? null : _openEditor,
                  child: const Text('編集する'),
                ),
                if (_processingFailed)
                  TextButton(
                    onPressed: _busy ? null : _prepare,
                    child: const Text('確認画像を再作成'),
                  ),
              ],
            )
          : Row(
              children: [
                Expanded(child: _kindChips()),
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
                  onPressed:
                      _busy || (!widget.includeOtherCandidates && _scanning)
                      ? null
                      : _prepare,
                ),
              ],
            ),
    ),
  );

  Widget _savedAction(
    String label,
    IconData icon,
    VoidCallback action, {
    bool primary = false,
  }) => TextButton.icon(
    onPressed: _busy ? null : action,
    style: TextButton.styleFrom(
      minimumSize: const Size(0, 48),
      backgroundColor: primary ? glassMint : Colors.transparent,
      foregroundColor: primary ? const Color(0xFF142A25) : Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    icon: Icon(icon, size: 20),
    label: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.fade,
      softWrap: false,
      style: const TextStyle(fontWeight: FontWeight.w600),
    ),
  );

  Future<void> _share() async {
    final jpeg = _preview;
    if (jpeg == null) return;
    if (!await _sharer.share(jpeg) && mounted) {
      _notify('共有できませんでした');
    }
  }

  Future<void> _open() async {
    if (!await _sharer.open() && mounted) {
      _notify('写真を開けませんでした。写真アプリから確認してください');
    }
  }

  void _notify(String message) =>
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));

  void _togglePreviewZoom() {
    if (_previewTransform.value.getMaxScaleOnAxis() > 1.01) {
      _previewTransform.value = Matrix4.identity();
      return;
    }
    const zoom = 3.0;
    final p = _previewTapPoint;
    _previewTransform.value = Matrix4.identity()
      ..translateByDouble(-p.dx * (zoom - 1), -p.dy * (zoom - 1), 0, 1)
      ..scaleByDouble(zoom, zoom, 1, 1);
  }

  Future<void> _openSettings() async {
    try {
      await const MethodChannel('dev.camereon/app_settings')
          .invokeMethod<void>('open');
    } catch (_) {
      /* Keep the edited image and allow another save attempt. */
    }
  }

  /// Frames under [point], nearest and smallest first. Shapes count, not boxes.
  List<RegionCandidate> _hits(Offset point, double scale) {
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
      final aContains = a.region.contains(point);
      final bContains = b.region.contains(point);
      if (aContains != bContains) return aContains ? -1 : 1;
      if (!aContains) {
        double distance(RegionCandidate c) {
          final r = c.region.toRect();
          final dx = math.max(
            0.0,
            math.max(r.left - point.dx, point.dx - r.right),
          );
          final dy = math.max(
            0.0,
            math.max(r.top - point.dy, point.dy - r.bottom),
          );
          return dx * dx + dy * dy;
        }

        final order = distance(a).compareTo(distance(b));
        if (order != 0) return order;
      }
      final aEdge = edgeDistance(a) <= tolerance;
      final bEdge = edgeDistance(b) <= tolerance;
      if (aEdge != bEdge) return aEdge ? -1 : 1;
      return (a.region.width * a.region.height).compareTo(
        b.region.width * b.region.height,
      );
    });
    return hits;
  }

  RegionCandidate? _hitCandidate(Offset point, double scale) {
    final hits = _hits(point, scale);
    return hits.isEmpty ? null : hits.first;
  }

  void _tapCandidate(Offset point, double scale) {
    final hits = _hits(point, scale);
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

  Widget _editor(SourcePhoto source) =>
      !widget.includeOtherCandidates && _scanning
      ? _loading()
      : LayoutBuilder(
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
            Offset toImage(Offset local) => (local - rect.topLeft) / scale;
            double tapScale() =>
                scale * _photoTransform.value.getMaxScaleOnAxis();
            return GestureDetector(
              key: const ValueKey('photo-canvas'),
              behavior: HitTestBehavior.opaque,
              onTapUp: _busy
                  ? null
                  : (event) {
                      if (rect.contains(event.localPosition)) {
                        _tapCandidate(toImage(event.localPosition), tapScale());
                      }
                    },
              onLongPressStart: _busy
                  ? null
                  : (event) =>
                        _strokeStart(toImage(event.localPosition), tapScale()),
              onLongPressMoveUpdate: _busy
                  ? null
                  : (event) =>
                        _strokeMove(toImage(event.localPosition), tapScale()),
              onLongPressEnd: _busy ? null : (_) => _strokeEnd(),
              onLongPressCancel: _busy ? null : _strokeEnd,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fromRect(
                    rect: rect,
                    child: RepaintBoundary(
                      // Decode at most 4096px on the long side: enough for 8x zoom
                      // on a phone, and a 20MP photo no longer needs an 83MB texture.
                      child: Image.memory(
                        source.bytes,
                        fit: BoxFit.fill,
                        cacheWidth: source.width >= source.height
                            ? math.min(source.width, displayDecodeSide)
                            : null,
                        cacheHeight: source.width < source.height
                            ? math.min(source.height, displayDecodeSide)
                            : null,
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
                          patches: Map.unmodifiable(_patches),
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

/// Selected areas: the frosted texture once ready, an opaque cover until then.
/// The original text must not show through while patches are being prepared.
class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.regions,
    required this.imageWidth,
    required this.imageHeight,
    this.patches = const {},
  });
  final List<HideRegion> regions;
  final Map<HideRegion, FrostedPatch> patches;
  final int imageWidth;
  final int imageHeight;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / imageWidth, size.height / imageHeight);
    final placeholder = Paint()..color = const Color(0xFFE2E8E5);
    final image = Paint()..filterQuality = FilterQuality.low;
    for (final region in regions) {
      final patch = patches[region];
      if (patch == null) {
        canvas.drawPath(region.toPath(), placeholder);
      } else {
        canvas.drawImageRect(
          patch.image,
          Rect.fromLTWH(
            0,
            0,
            patch.image.width.toDouble(),
            patch.image.height.toDouble(),
          ),
          patch.bounds,
          image,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) =>
      oldDelegate.imageWidth != imageWidth ||
      oldDelegate.imageHeight != imageHeight ||
      oldDelegate.regions != regions ||
      oldDelegate.patches != patches;
}
