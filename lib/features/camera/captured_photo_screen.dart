import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/analysis/face_detection.dart';
import '../../core/analysis/infrastructure/mlkit_face_detector.dart';
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
import '../detection/candidate_overlay.dart';
import 'glass_photo_chrome.dart';

/// Longest side of the editor's decoded photo texture.
const displayDecodeSide = 4096;

/// Brush radius on screen, in logical pixels. Zooming in paints finer lines.
const brushScreenRadius = 14.0;

/// Pen hides, eraser shows again. Both are freehand strokes.
enum EditTool { pen, eraser }

/// The editor opens right after capture with everything detected already
/// hidden, and saves from there. Frames toggle with a tap, one finger paints
/// with the current tool, two fingers zoom and pan. Every change can be undone
/// and redone, and nothing is written until the user saves.
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
    this.sharer,
    this.autoHideKinds = const {CandidateKind.address, CandidateKind.face},
  });

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

  /// Detected kinds that start hidden. Other kinds still get frames to tap.
  final Set<CandidateKind> autoHideKinds;
  @override
  State<CapturedPhotoScreen> createState() => _CapturedPhotoScreenState();
}

typedef _Mask = ({RegionCandidate? candidate, HideRegion region});

/// Selected frames and brush strokes in the order they were applied.
class _Snapshot {
  _Snapshot(Iterable<_Mask> masks) : masks = List.unmodifiable(masks);

  final List<_Mask> masks;
  late final selected = {for (final mask in masks) ?mask.candidate};
  late final regions = _regions();

  List<HideRegion> _regions() {
    final seen = <HideRegion>{};
    // Coincident frames still toggle independently. Draw their shape at its
    // most recent position so reselecting a frame hides earlier erasures.
    return [
      for (final mask in masks.reversed)
        if (mask.candidate == null || seen.add(mask.region)) mask.region,
    ].reversed.toList(growable: false);
  }

  _Snapshot hide(Iterable<RegionCandidate> candidates) => _Snapshot([
    ...masks,
    for (final candidate in candidates)
      if (!selected.contains(candidate))
        (candidate: candidate, region: candidate.region),
  ]);
}

/// The stroke under the finger. Repaints only the selection layer.
@visibleForTesting
class LiveStroke extends ChangeNotifier {
  final List<Offset> points = [];
  double radius = 0;
  bool reveal = false;
  Offset? finger;
  bool get active => points.isNotEmpty;

  void start(Offset point, double radius, bool reveal, Offset finger) {
    points
      ..clear()
      ..add(point);
    this.radius = radius;
    this.reveal = reveal;
    this.finger = finger;
    notifyListeners();
  }

  void extend(Offset point, Offset finger) {
    this.finger = finger;
    if ((point - points.last).distance >= radius * .35 &&
        points.length < 4000) {
      points.add(point);
    }
    notifyListeners();
  }

  void clear() {
    points.clear();
    finger = null;
    notifyListeners();
  }
}

const _kindIcons = <CandidateKind, IconData>{
  CandidateKind.address: Icons.home_rounded,
  CandidateKind.text: Icons.text_fields_rounded,
  CandidateKind.face: Icons.face_rounded,
  CandidateKind.person: Icons.person_rounded,
  CandidateKind.screen: Icons.monitor_rounded,
  CandidateKind.vehicle: Icons.directions_car_rounded,
};

class _CapturedPhotoScreenState extends State<CapturedPhotoScreen>
    with WidgetsBindingObserver {
  late final PhotoProcessor _processor =
      widget.processor ?? FlutterPhotoProcessor();
  late final PhotoSaver _saver = widget.saver ?? AndroidPhotoSaver();
  late final PhotoSharer _sharer = widget.sharer ?? PlatformPhotoSharer();
  late final RegionDetector _detector =
      widget.detector ?? const NoRegionDetector();
  late final RegionDetector _addressDetector =
      widget.addressDetector ?? JapaneseAddressDetector();
  bool _addressDetecting = false;
  bool _addressFailed = false;
  final Set<HideRegion> _seenAddresses = {};
  late final RegionDetector _objectDetector =
      widget.objectDetector ?? const NoRegionDetector();
  late final _faces = FaceDetectionController(
    widget.faceDetector ?? MlKitFaceDetector(),
  );
  late final FrostedPreviewer _previewer =
      widget.previewer ?? FrostedPreviewer();
  // Frosted textures per hidden region; drawn as-is while zooming.
  final Map<HideRegion, FrostedPatch> _patches = {};
  final Set<HideRegion> _pendingPatches = {};
  Timer? _patchTimer;
  final Map<String, RegionCandidate> _faceCandidates = {};
  List<RegionCandidate> _candidates = [];
  _Snapshot _edits = _Snapshot(const []);
  Set<RegionCandidate> get _selected => _edits.selected;
  final List<_Snapshot> _undoStack = [];
  final List<_Snapshot> _redoStack = [];
  EditTool _tool = EditTool.pen;
  final _live = LiveStroke();
  // Fingers on the photo. Once two touch, nothing paints until all lift.
  int _pointers = 0;
  Offset? _strokeStart;
  bool _multiTouch = false;
  bool _pinching = false;
  bool _peeking = false;
  final _photoTransform = TransformationController();
  // Pinch state: the content point under the fingers stays under them.
  Matrix4 _pinchStart = Matrix4.identity();
  Offset _pinchFocus = Offset.zero;
  double _pinchScale = 1;
  Size _viewport = Size.zero;
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

  List<HideRegion> get _redactions => _edits.regions;
  bool get _scanning =>
      _addressDetecting ||
      _detecting ||
      _faces.status == FaceDetectionStatus.detecting;
  bool get _scanIncomplete =>
      _addressFailed ||
      _failedScans.isNotEmpty ||
      _faces.status == FaceDetectionStatus.failed ||
      _faces.status == FaceDetectionStatus.cancelled;
  bool get _canRetry =>
      !_scanning &&
      (_addressFailed || _failedScans.isNotEmpty || _faces.canRetry);

  /// Automatic results stay hidden behind the scan until they are complete,
  /// so the original never shows with a missing mask.
  bool get _hiddenWhileScanning => !widget.includeOtherCandidates && _scanning;
  bool get _canEdit => !_busy && _source != null && !_hiddenWhileScanning;

  /// Only the user's own changes ask before being thrown away.
  bool get _edited => _undoStack.isNotEmpty;
  SourcePhoto? _source;
  RedactedJpeg? _savedJpeg;
  bool _busy = true;
  bool _loadFailed = false;
  String _loadError = '写真を読み込めませんでした';
  bool _saved = false;
  bool _allowPop = false;

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
          if (!widget.includeOtherCandidates) _hideAutomatically(candidate);
          return candidate;
        });
      }
    });
    _schedulePatches();
  }

  /// Automatic discovery isn't an undo step. Undoing or redoing an earlier
  /// user action must not reveal something found after that action.
  void _hideAutomatically(RegionCandidate candidate) {
    if (!widget.autoHideKinds.contains(candidate.kind)) return;
    final previous = _redactions;
    _edits = _edits.hide([candidate]);
    for (final stack in [_undoStack, _redoStack]) {
      for (var i = 0; i < stack.length; i++) {
        stack[i] = stack[i].hide([candidate]);
      }
    }
    if (!listEquals(previous, _redactions)) _invalidateSavedPhoto();
  }

  void _invalidateSavedPhoto() {
    _saved = false;
    _savedJpeg = null;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    scheduleMicrotask(_startAutomaticDetection);
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
    _live.dispose();
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
        _edits = _Snapshot(const []).hide(
          initial.where(
            (candidate) =>
                widget.includeOtherCandidates ||
                widget.autoHideKinds.contains(candidate.kind),
          ),
        );
        _undoStack.clear();
        _redoStack.clear();
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
    if (source == null) return;
    if (WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
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
        !identical(source, _source)) {
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
      if (!mounted || epoch != _detectionEpoch) return;
      setState(() {
        for (final c in result.candidates) {
          if (c.kind != CandidateKind.address || _knownAddress(c.region)) {
            continue;
          }
          _seenAddresses.add(c.region);
          _candidates.add(c);
          _hideAutomatically(c);
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
      if (!mounted || epoch != _detectionEpoch || !identical(source, _source)) {
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
                [
                  ..._undoStack,
                  ..._redoStack,
                ].any((snapshot) => snapshot.selected.contains(c)) ||
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
    if (_busy || _live.active || !_canRetry || source == null) return;
    if (_faces.canRetry) unawaited(_faces.detect(source));
    if (!widget.includeOtherCandidates) {
      unawaited(_detectAddresses(source));
      return;
    }
    unawaited(_detectAll(source));
  }

  // --- Editing: every change is one undo step. ---------------------------

  void _apply(_Snapshot next) {
    setState(() {
      _undoStack.add(_edits);
      _redoStack.clear();
      _edits = next;
      _invalidateSavedPhoto();
    });
    unawaited(HapticFeedback.selectionClick());
    _schedulePatches();
  }

  void _toggle(RegionCandidate candidate) {
    if (!_canEdit) return;
    _toggleFrames({candidate});
  }

  /// Hide every frame of one kind, or show them all again when all are hidden.
  void _toggleKind(CandidateKind? kind) {
    if (!_canEdit) return;
    final frames = _visibleCandidates
        .where((c) => kind == null || c.kind == kind)
        .toSet();
    if (frames.isNotEmpty) _toggleFrames(frames);
  }

  void _toggleFrames(Set<RegionCandidate> frames) {
    final allHidden = frames.every(_selected.contains);
    _apply(
      allHidden
          ? _Snapshot(
              _edits.masks.where((mask) => !frames.contains(mask.candidate)),
            )
          : _edits.hide(frames),
    );
  }

  void _undo() => _step(_undoStack, _redoStack);
  void _redo() => _step(_redoStack, _undoStack);

  void _step(List<_Snapshot> from, List<_Snapshot> to) {
    if (_busy || from.isEmpty) return;
    setState(() {
      to.add(_edits);
      _edits = from.removeLast();
      _invalidateSavedPhoto();
    });
    unawaited(HapticFeedback.selectionClick());
    _schedulePatches();
  }

  // --- Gestures: tap toggles a frame, one finger paints, two fingers zoom. --

  Offset _toContent(Offset local) {
    final m = _photoTransform.value;
    final zoom = m.getMaxScaleOnAxis();
    final t = m.getTranslation();
    return Offset((local.dx - t.x) / zoom, (local.dy - t.y) / zoom);
  }

  void _pointerDown(PointerDownEvent event) {
    _pointers++;
    if (_pointers == 1) {
      _strokeStart = event.localPosition;
      return;
    }
    // A second finger means zoom: the stroke so far was not meant to paint.
    _multiTouch = true;
    _clearStroke();
  }

  void _pointerUp(PointerEvent _) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers == 0) {
      _strokeStart = null;
      _multiTouch = false;
    }
  }

  void _pointerCancel(PointerCancelEvent event) {
    _clearStroke();
    _pointerUp(event);
  }

  void _clearStroke() {
    if (_live.active) setState(_live.clear);
  }

  void _scaleStart(ScaleStartDetails d, Rect photo, double fit) {
    if (!_canEdit) return;
    if (d.pointerCount >= 2) {
      _startPinch(d.localFocalPoint, 1);
      return;
    }
    final start = _strokeStart;
    if (_multiTouch || start == null) return;
    final content = _toContent(start);
    final radius =
        brushScreenRadius / (fit * _photoTransform.value.getMaxScaleOnAxis());
    // Strokes start on the photo; the margin around it is left alone.
    if (!photo.inflate(radius * fit).contains(content)) return;
    setState(() {
      _live.start(
        (content - photo.topLeft) / fit,
        radius,
        _tool == EditTool.eraser,
        d.localFocalPoint,
      );
      _live.extend(
        (_toContent(d.localFocalPoint) - photo.topLeft) / fit,
        d.localFocalPoint,
      );
    });
  }

  void _scaleUpdate(ScaleUpdateDetails d, Rect photo, double fit) {
    if (!_canEdit) return;
    if (d.pointerCount >= 2) {
      _clearStroke();
      if (!_pinching) _startPinch(d.localFocalPoint, d.scale);
      _updatePinch(d);
      return;
    }
    if (_multiTouch || !_live.active) return;
    final content = _toContent(d.localFocalPoint);
    _live.extend((content - photo.topLeft) / fit, d.localFocalPoint);
  }

  void _scaleEnd(ScaleEndDetails d) {
    _pinching = false;
    _commitStroke();
  }

  void _startPinch(Offset focus, double scale) {
    _pinching = true;
    _pinchStart = _photoTransform.value.clone();
    _pinchFocus = focus;
    _pinchScale = scale;
  }

  void _updatePinch(ScaleUpdateDetails d) {
    final startZoom = _pinchStart.getMaxScaleOnAxis();
    final zoom = (startZoom * d.scale / _pinchScale).clamp(1.0, 8.0);
    final t = _pinchStart.getTranslation();
    final anchor = Offset(
      (_pinchFocus.dx - t.x) / startZoom,
      (_pinchFocus.dy - t.y) / startZoom,
    );
    var dx = d.localFocalPoint.dx - anchor.dx * zoom;
    var dy = d.localFocalPoint.dy - anchor.dy * zoom;
    // Keep the zoomed content covering the view.
    dx = dx.clamp(_viewport.width * (1 - zoom), 0.0);
    dy = dy.clamp(_viewport.height * (1 - zoom), 0.0);
    _photoTransform.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(zoom, zoom, 1, 1);
  }

  void _commitStroke() {
    final source = _source;
    if (!_live.active || source == null || !_canEdit) {
      _clearStroke();
      return;
    }
    final region = HideRegion.stroke(
      List.of(_live.points),
      _live.radius,
      imageWidth: source.width,
      imageHeight: source.height,
      reveal: _live.reveal,
    );
    _clearStroke();
    if (region == null) return;
    // An eraser stroke over nothing hidden would only be a confusing undo step.
    if (region.reveal &&
        !_redactions.any(
          (r) => !r.reveal && r.toRect().overlaps(region.toRect()),
        )) {
      return;
    }
    _apply(_Snapshot([..._edits.masks, (candidate: null, region: region)]));
  }

  void _schedulePatches() {
    _patchTimer?.cancel();
    _patchTimer = Timer(const Duration(milliseconds: 120), _refreshPatches);
  }

  /// Keep one frosted texture per hidden region, computed off the UI thread.
  Future<void> _refreshPatches() async {
    if (!mounted) return;
    final wanted = {
      for (final r in _redactions)
        if (!r.reveal) r,
    };
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
          if (!mounted || !_redactions.contains(region)) {
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
    if (_edited && !_saved) {
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

  bool get _canSave => _canEdit && !_live.active && !_saved;
  bool get _canShare => _saved && !_busy && !_scanning && !_live.active;

  /// Renders the committed masks and saves the photo in one step.
  Future<void> _save() async {
    final source = _source;
    if (!_canSave || source == null) return;
    if (_scanIncomplete) {
      // Saving after a failed scan is allowed, but never by accident.
      final retryAvailable = _canRetry;
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('一部を検出できませんでした'),
          content: const Text('隠し忘れがないか確認してから保存してください。'),
          actions: [
            TextButton(
              onPressed: () =>
                  Navigator.pop(context, retryAvailable ? false : null),
              child: Text(retryAvailable ? 'もう一度検出' : '編集に戻る'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('このまま保存'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (choice == false) _retry();
      if (choice != true || !_canSave) return;
    }
    if (_scanning) {
      // Legacy editor: stop the scans; the retry button finishes them later.
      _faces.cancel();
      if (_detecting) _failedScans.addAll({false, true});
      _detectionEpoch++;
      _autoDetectionEpoch++;
      _detecting = false;
    }
    setState(() => _busy = true);
    RedactedJpeg jpeg;
    try {
      jpeg = await _processor.redact(source, List.of(_redactions));
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      _notify('加工できませんでした。編集内容はそのままです');
      return;
    }
    SaveResult result;
    try {
      result = await _saver.save(jpeg);
    } catch (_) {
      result = const SaveFailed(SaveFailureReason.failed);
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (result is SaveSucceeded) {
        _saved = true;
        _savedJpeg = jpeg;
      }
    });
    switch (result) {
      case SaveSucceeded():
        unawaited(HapticFeedback.mediumImpact());
      case SaveFailed(reason: SaveFailureReason.permissionDenied):
        _notify(
          '保存の許可を設定から確認してください',
          action: SnackBarAction(label: '設定を開く', onPressed: _openSettings),
        );
      case SaveFailed():
        _notify('保存できませんでした。もう一度お試しください');
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = _source;
    return PopScope(
      canPop: !_busy && (_allowPop || !_edited || _saved),
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
                  if (source == null) _loading() else _editor(source),
                  Positioned(
                    top: 16,
                    left: 16,
                    child: PhotoGlass(
                      child: GlassIconButton(
                        label: _saved ? 'もう一枚' : '撮り直す',
                        icon: _saved
                            ? Icons.photo_camera_outlined
                            : Icons.close_rounded,
                        onPressed: _busy ? null : _retake,
                      ),
                    ),
                  ),
                  if (source != null)
                    Positioned(top: 16, right: 16, child: _statusBar()),
                  if (source != null)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: 16,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 420),
                          child: _dock(),
                        ),
                      ),
                    ),
                  _loupe(),
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

  /// Icons only: progress, a failed scan to retry, the saved photo to open,
  /// and a press-and-hold look at the original.
  Widget _statusBar() {
    final hidden = _redactions.any((r) => !r.reveal);
    final children = <Widget>[
      if (_busy || _scanning)
        Semantics(
          label: _busy ? '仕上げています' : '検出中',
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: glassMint,
                // Reduced motion: a still ring instead of a spinner.
                value: MediaQuery.disableAnimationsOf(context) ? .3 : null,
              ),
            ),
          ),
        )
      else if (_scanIncomplete)
        IconButton(
          tooltip: '一部を検出できませんでした',
          onPressed: _canRetry && !_live.active ? _retry : null,
          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
          icon: const Icon(
            Icons.refresh_rounded,
            color: Color(0xFFFFCB8A),
            size: 22,
          ),
        )
      else if (_saved)
        GlassIconButton(
          label: '写真アプリで開く',
          icon: Icons.check_circle_rounded,
          onPressed: _open,
        )
      else if (_truncated)
        const Tooltip(
          message: '一部の候補を表示しています',
          child: Padding(
            padding: EdgeInsets.all(13),
            child: Icon(Icons.info_outline_rounded, color: Colors.white70),
          ),
        ),
      if (hidden && !_hiddenWhileScanning) _peekButton(),
    ];
    if (children.isEmpty) return const SizedBox.shrink();
    return PhotoGlass(
      child: Row(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  /// Hold to see the photo without masks; release to hide them again.
  Widget _peekButton() => Semantics(
    button: true,
    label: '押している間、元の写真を表示',
    child: Listener(
      onPointerDown: (_) => setState(() => _peeking = true),
      onPointerUp: (_) => setState(() => _peeking = false),
      onPointerCancel: (_) => setState(() => _peeking = false),
      child: SizedBox(
        key: const ValueKey('peek-original'),
        width: 48,
        height: 48,
        child: Icon(
          _peeking ? Icons.visibility_rounded : Icons.visibility_outlined,
          color: _peeking ? glassMint : Colors.white,
          size: 22,
        ),
      ),
    ),
  );

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
    final color = all ? const Color(0xFF142A25) : Colors.white;
    return Padding(
      key: ValueKey('kind-chip-${kind?.name ?? 'all'}'),
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Semantics(
        button: true,
        toggled: all,
        label: '$labelを${all ? '表示' : '隠す'}',
        excludeSemantics: true,
        child: InkWell(
          onTap: _canEdit ? () => _toggleKind(kind) : null,
          borderRadius: BorderRadius.circular(24),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            constraints: const BoxConstraints(minHeight: 40, minWidth: 56),
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  kind == null
                      ? Icons.select_all_rounded
                      : _kindIcons[kind] ?? Icons.crop_square_rounded,
                  size: 18,
                  color: color,
                ),
                const SizedBox(width: 6),
                Text(
                  hidden > 0 && !all ? '$hidden/$total' : '$total',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _dock() {
    final chips = !_hiddenWhileScanning && _visibleCandidates.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (chips) ...[
          PhotoGlass(
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: _kindChips(),
            ),
          ),
          const SizedBox(height: 10),
        ],
        PhotoGlass(
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              children: [
                _toolButton(
                  EditTool.pen,
                  'ペンで隠す',
                  const Icon(Icons.brush_rounded, size: 22),
                ),
                _toolButton(EditTool.eraser, '消しゴムで戻す', const EraserIcon()),
                const SizedBox(width: 4),
                Container(width: 1, height: 20, color: Colors.white12),
                const SizedBox(width: 4),
                GlassIconButton(
                  label: '取り消す',
                  icon: Icons.undo_rounded,
                  onPressed: _busy || _undoStack.isEmpty ? null : _undo,
                ),
                GlassIconButton(
                  label: 'やり直す',
                  icon: Icons.redo_rounded,
                  onPressed: _busy || _redoStack.isEmpty ? null : _redo,
                ),
                const Spacer(),
                if (_saved)
                  GlassIconButton(
                    label: '共有',
                    icon: Icons.ios_share_rounded,
                    primary: true,
                    onPressed: _canShare ? _share : null,
                  )
                else
                  GlassIconButton(
                    label: '写真に保存',
                    icon: Icons.download_rounded,
                    primary: true,
                    onPressed: _canSave ? _save : null,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolButton(EditTool tool, String label, Widget icon) {
    final active = _tool == tool;
    return Semantics(
      selected: active,
      child: IconButton(
        tooltip: label,
        isSelected: active,
        onPressed: _canEdit ? () => setState(() => _tool = tool) : null,
        style: IconButton.styleFrom(
          minimumSize: const Size(48, 48),
          backgroundColor: active
              ? Colors.white.withValues(alpha: .16)
              : Colors.transparent,
          foregroundColor: active ? glassMint : Colors.white,
          disabledForegroundColor: Colors.white30,
        ),
        icon: icon,
      ),
    );
  }

  /// A magnified view above the finger: the spot being painted is never
  /// hidden under it. The ring shows the brush size.
  Widget _loupe() => ListenableBuilder(
    listenable: _live,
    builder: (context, _) {
      final finger = _live.finger;
      if (finger == null || !_live.active) return const SizedBox.shrink();
      const size = 112.0;
      const lift = 96.0;
      final above = finger.dy - lift - size / 2 >= 0;
      final offset = Offset(0, above ? lift : -lift);
      final center = finger - offset;
      const ring = brushScreenRadius * 1.6;
      return Positioned(
        left: center.dx - size / 2,
        top: center.dy - size / 2,
        child: IgnorePointer(
          child: RawMagnifier(
            size: const Size(size, size),
            focalPointOffset: offset,
            magnificationScale: 1.6,
            decoration: const MagnifierDecoration(
              shape: CircleBorder(side: BorderSide(color: glassMint, width: 2)),
            ),
            child: Center(
              child: Container(
                width: ring * 2,
                height: ring * 2,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  // Dark ring with a light halo: visible on paper and on night.
                  border: Border.all(color: Colors.black54, width: 1.2),
                  boxShadow: const [
                    BoxShadow(color: Colors.white54, spreadRadius: 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  Future<void> _share() async {
    final jpeg = _savedJpeg;
    if (!_canShare || jpeg == null) return;
    if (!await _sharer.share(jpeg) && mounted) {
      _notify('共有できませんでした');
    }
  }

  Future<void> _open() async {
    if (!await _sharer.open() && mounted) {
      _notify('写真を開けませんでした。写真アプリから確認してください');
    }
  }

  void _notify(String message, {SnackBarAction? action}) =>
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            action: action,
            // Float above the dock: the save button stays reachable.
            behavior: SnackBarBehavior.floating,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 168),
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

  Widget _editor(SourcePhoto source) => LayoutBuilder(
    builder: (context, constraints) {
      _viewport = constraints.biggest;
      final available = Size(
        math.max(1, constraints.maxWidth - 24),
        math.max(1, constraints.maxHeight - 236),
      );
      final fit = math.min(
        available.width / source.width,
        available.height / source.height,
      );
      final photo = Alignment.center.inscribe(
        Size(source.width * fit, source.height * fit),
        Rect.fromLTWH(12, 76, available.width, available.height),
      );
      final scanning = _hiddenWhileScanning;
      final image = RepaintBoundary(
        // Decode at most 4096px on the long side: enough for 8x zoom
        // on a phone, and a 20MP photo no longer needs an 83MB texture.
        child: Image.memory(
          excludeFromSemantics: scanning,
          source.bytes,
          fit: BoxFit.fill,
          cacheWidth: source.width >= source.height
              ? math.min(source.width, displayDecodeSide)
              : null,
          cacheHeight: source.width < source.height
              ? math.min(source.height, displayDecodeSide)
              : null,
          semanticLabel: scanning ? null : '撮影した写真',
        ),
      );
      return Listener(
        onPointerDown: _pointerDown,
        onPointerUp: _pointerUp,
        onPointerCancel: _pointerCancel,
        child: GestureDetector(
          key: const ValueKey('photo-canvas'),
          behavior: HitTestBehavior.opaque,
          dragStartBehavior: DragStartBehavior.down,
          onTapUp: _canEdit
              ? (event) {
                  final content = _toContent(event.localPosition);
                  if (photo.contains(content)) {
                    _tapCandidate(
                      (content - photo.topLeft) / fit,
                      fit * _photoTransform.value.getMaxScaleOnAxis(),
                    );
                  }
                }
              : null,
          onScaleStart: (d) => _scaleStart(d, photo, fit),
          onScaleUpdate: (d) => _scaleUpdate(d, photo, fit),
          onScaleEnd: _scaleEnd,
          child: ClipRect(
            child: AnimatedBuilder(
              animation: _photoTransform,
              builder: (context, child) =>
                  Transform(transform: _photoTransform.value, child: child),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fromRect(
                    rect: photo,
                    // Until detection finishes the photo stays unreadable.
                    child: scanning
                        ? ImageFiltered(
                            imageFilter: ui.ImageFilter.blur(
                              sigmaX: 24,
                              sigmaY: 24,
                              tileMode: TileMode.decal,
                            ),
                            child: image,
                          )
                        : image,
                  ),
                  if (!scanning && !_peeking) ...[
                    Positioned.fromRect(
                      rect: photo,
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: SelectionPainter(
                            regions: List.unmodifiable(_redactions),
                            patches: Map.unmodifiable(_patches),
                            imageWidth: source.width,
                            imageHeight: source.height,
                            live: _live,
                          ),
                        ),
                      ),
                    ),
                    Positioned.fromRect(
                      rect: photo,
                      child: RepaintBoundary(
                        child: CandidateOverlay(
                          candidates: _visibleCandidates,
                          selectedCandidates: Set.unmodifiable(_selected),
                          imageWidth: source.width,
                          imageHeight: source.height,
                          onToggle: _canEdit ? _toggle : null,
                        ),
                      ),
                    ),
                  ],
                  Positioned.fromRect(
                    rect: photo,
                    child: RepaintBoundary(
                      child: PhotoScanEffect(active: _scanning),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// An eraser: a tilted block with a filled tip. Material has no such icon.
class EraserIcon extends StatelessWidget {
  const EraserIcon({super.key, this.size = 22});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _EraserPainter(IconTheme.of(context).color!)),
  );
}

class _EraserPainter extends CustomPainter {
  _EraserPainter(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    canvas.rotate(-math.pi / 4);
    final body = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 18 * s, height: 9 * s),
      Radius.circular(2 * s),
    );
    canvas.drawRRect(
      body,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8 * s,
    );
    canvas.clipRRect(body);
    canvas.drawRect(
      Rect.fromLTRB(-9 * s, -4.5 * s, -2 * s, 4.5 * s),
      Paint()..color = color,
    );
    canvas.restore();
    canvas.drawLine(
      Offset(13 * s, 21 * s),
      Offset(21 * s, 21 * s),
      Paint()
        ..color = color
        ..strokeWidth = 1.8 * s
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_EraserPainter oldDelegate) => oldDelegate.color != color;
}

/// Hidden areas, in order: the frosted texture once ready, an opaque cover
/// until then, so the original never shows through while patches are being
/// prepared. Eraser strokes cut through everything painted before them.
class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.regions,
    required this.imageWidth,
    required this.imageHeight,
    this.patches = const {},
    LiveStroke? live,
  }) : _live = live,
       super(repaint: live);
  final List<HideRegion> regions;
  final Map<HideRegion, FrostedPatch> patches;
  final int imageWidth;
  final int imageHeight;
  final LiveStroke? _live;

  static final _placeholder = Paint()..color = const Color(0xFFE2E8E5);
  static final _rim = glassMint.withValues(alpha: .9);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.scale(size.width / imageWidth, size.height / imageHeight);
    final bounds = Rect.fromLTWH(
      0,
      0,
      imageWidth.toDouble(),
      imageHeight.toDouble(),
    );
    // Erasers clear this layer only, showing the photo underneath.
    canvas.saveLayer(bounds, Paint());
    final image = Paint()..filterQuality = FilterQuality.low;
    // About 1.5 logical pixels: the frost blends in, the rim shows the edge.
    final rim = 1.5 * imageWidth / size.width;
    for (final region in regions) {
      if (region.reveal || region.shape == HideShape.stroke) {
        if (!region.reveal) {
          _stroke(canvas, region.points, region.radius + rim, false, _rim);
        }
        _stroke(canvas, region.points, region.radius, region.reveal);
        if (region.reveal) continue;
      }
      final patch = patches[region];
      if (patch == null) {
        if (region.shape != HideShape.stroke) {
          canvas.drawPath(region.toPath(), _placeholder);
        }
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
    final live = _live;
    if (live != null && live.active) {
      if (!live.reveal) {
        _stroke(canvas, live.points, live.radius + rim, false, _rim);
      }
      _stroke(canvas, live.points, live.radius, live.reveal);
    }
    canvas.restore();
    canvas.restore();
  }

  /// Pen: opaque cover (the frosted texture is drawn over it when ready).
  /// Eraser: clears what is below in the layer.
  void _stroke(
    Canvas canvas,
    List<Offset> points,
    double radius,
    bool clear, [
    Color? color,
  ]) {
    final paint = Paint()
      ..color = color ?? _placeholder.color
      ..blendMode = clear ? BlendMode.clear : BlendMode.srcOver;
    if (points.length == 1) {
      canvas.drawCircle(points.first, radius, paint);
      return;
    }
    paint
      ..style = PaintingStyle.stroke
      ..strokeWidth = radius * 2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(Path()..addPolygon(points, false), paint);
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) =>
      oldDelegate.imageWidth != imageWidth ||
      oldDelegate.imageHeight != imageHeight ||
      oldDelegate.regions != regions ||
      oldDelegate.patches != patches;
}
