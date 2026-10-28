import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import '../../core/analysis/face_detection.dart';
import '../../core/analysis/infrastructure/mlkit_face_detector.dart';
import '../analysis/face_detection_controller.dart';
import '../analysis/photo_analysis_entry.dart';
import 'photo_edit_state.dart';
import '../../core/detection/android_text_region_detector.dart';
import '../../core/detection/android_object_region_detector.dart';
import '../../core/detection/region_detector.dart';
import '../detection/candidate_overlay.dart';
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
  String _detectionSubject = '文字';
  List<RegionCandidate> _candidates = [];
  bool _detecting = false;
  final Map<bool, String> _detectionMessages = {};
  int _detectionEpoch = 0;
  int _autoDetectionEpoch = 0;
  bool _automaticDetectionStarted = false;
  bool _facesOnly = false;
  List<RegionCandidate> get _visibleCandidates =>
      _facesOnly ? const [] : _candidates;
  // Selection belongs to a candidate, not its geometry. Person/text candidates
  // can share a rectangle and must still toggle independently.
  final Set<RegionCandidate> _selectedCandidates = {};
  Set<HideRegion> get _selectedCandidateRegions => {
    for (final candidate in _selectedCandidates) candidate.region,
  };
  List<HideRegion> get _redactions =>
      <HideRegion>{..._regions, ..._selectedCandidateRegions}.toList();
  SourcePhoto? _source;
  RedactedJpeg? _preview;
  final _edits = PhotoEditState();
  List<HideRegion> get _regions => _edits.regions;
  late final _faces = FaceDetectionController(
    widget.faceDetector ?? MlKitFaceDetector(),
  );
  bool _covered = false;
  Offset? _start;
  Offset? _pointerStart;
  bool _dragging = false;
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
    WidgetsBinding.instance.addObserver(this);
    _faces.addListener(_faceChanged);
    _load();
  }

  void _faceChanged() {
    if (mounted) setState(() {});
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
      widget.onSourceLoaded?.call(source);
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
    // Run the two ONNX models in sequence to avoid simultaneous peak memory.
    // Each scan handles its own failure, so one failure never skips the other.
    await _detect();
    if (!mounted ||
        epoch != _autoDetectionEpoch ||
        !identical(source, _source) ||
        _preview != null) {
      return;
    }
    await _detect(objects: true);
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

  Future<void> _detect({bool objects = false}) async {
    final source = _source;
    if (_busy || _detecting || source == null) return;
    final epoch = ++_detectionEpoch;
    setState(() {
      _detecting = true;
      _detectionSubject = objects ? '人物・画面' : '文字';
      _detectionMessages.remove(objects);
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
        final scannedKinds = objects
            ? {CandidateKind.person, CandidateKind.screen}
            : {CandidateKind.text};
        // Retain numbering for matching candidates, even if a rescan returns a
        // different order. Keep selected older candidates available to deselect.
        _candidates = [
          for (final candidate in previous)
            if (!scannedKinds.contains(candidate.kind) ||
                _selectedCandidates.contains(candidate) ||
                result.candidates.any((next) => same(candidate, next)))
              candidate,
          for (final candidate in result.candidates)
            if (!previous.any((old) => same(candidate, old))) candidate,
        ];
        _detectionMessages[objects] = result.candidates.isEmpty
            ? '$_detectionSubject候補が見つかりませんでした。見落としもあるため、ご自身でも確認してください。'
            : result.truncated
            ? '候補が多いため一部のみ表示しています。画像全体も確認してください。'
            : '$_detectionSubjectの候補 ${result.candidates.length}件';
      });
    } catch (_) {
      if (mounted && epoch == _detectionEpoch) {
        setState(
          () => _detectionMessages[objects] =
              '$_detectionSubject候補を検出できませんでした。再試行するか、ドラッグして選択してください。',
        );
      }
    } finally {
      if (mounted && epoch == _detectionEpoch) {
        setState(() => _detecting = false);
      }
    }
  }

  void _toggleCandidate(RegionCandidate candidate) {
    if (_busy) return;
    setState(() {
      if (!_selectedCandidates.remove(candidate)) {
        _selectedCandidates.add(candidate);
      }
    });
  }

  void _applyAllCandidates() {
    if (_busy) return;
    setState(() {
      _selectedCandidates.addAll(_visibleCandidates);
      for (final candidate in _faces.candidates) {
        if (!_edits.isApplied(candidate.id)) _edits.toggle(candidate);
      }
    });
  }

  Widget _candidateControls() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!_facesOnly)
        OutlinedButton.icon(
          onPressed: _busy || _detecting || _source == null
              ? null
              : () => _detect(objects: true),
          icon: const Icon(Icons.person_search_outlined),
          label: Text(
            _detecting && _detectionSubject == '人物・画面'
                ? '人物・画面の候補を探しています…'
                : '人物・画面の候補を探す',
          ),
        ),
      if (!_facesOnly)
        OutlinedButton.icon(
          onPressed: _busy || _detecting || _source == null
              ? null
              : () => _detect(),
          icon: const Icon(Icons.text_fields),
          label: Text(
            _detecting && _detectionSubject == '文字'
                ? '文字候補を探しています…'
                : '文字の候補を探す',
          ),
        ),
      if (_detecting) ...[
        const LinearProgressIndicator(),
        Text('$_detectionSubjectの候補を検出中（手動編集・保存できます）'),
      ],
      if (!_facesOnly)
        for (final message in _detectionMessages.values) Text(message),
      if (_visibleCandidates.isNotEmpty) ...[
        Text('${_visibleCandidates.length}件の候補（選択中は黒塗り・もう一度押すと解除）'),
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 96),
          child: SingleChildScrollView(
            child: Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < _visibleCandidates.length; i++)
                  FilterChip(
                    key: ValueKey('candidate-toggle-$i'),
                    label: Text(
                      '${_visibleCandidates[i].kind.label}候補 ${i + 1}',
                    ),
                    selected: _selectedCandidates.contains(
                      _visibleCandidates[i],
                    ),
                    showCheckmark: false,
                    avatar: Icon(
                      _selectedCandidates.contains(_visibleCandidates[i])
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 18,
                    ),
                    onSelected: _busy
                        ? null
                        : (_) => _toggleCandidate(_visibleCandidates[i]),
                  ),
              ],
            ),
          ),
        ),
      ],
      if (_visibleCandidates.isNotEmpty || _faces.candidates.isNotEmpty)
        TextButton(
          onPressed:
              _busy ||
                  (_visibleCandidates.every(
                        (c) => _selectedCandidates.contains(c),
                      ) &&
                      _faces.candidates.every((c) => _edits.isApplied(c.id)))
              ? null
              : _applyAllCandidates,
          child: Text(_facesOnly ? '顔をすべて適用' : '候補をすべて適用'),
        ),
    ],
  );

  Future<void> _prepare() async {
    final source = _source;
    if (_busy || source == null) return;
    _faces.cancel();
    setState(() {
      _detectionEpoch++;
      _autoDetectionEpoch++;
      _detecting = false;
      _busy = true;
      _processingFailed = false;
      _pointer = null;
      _start = null;
      _drag = null;
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
                flex: 1,
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
                          '${_redactions.length}箇所の領域を選択中',
                          textAlign: TextAlign.center,
                        ),
                        const Text(
                          '枠をタップして黒塗り・解除／ドラッグで範囲を追加',
                          textAlign: TextAlign.center,
                        ),
                        SegmentedButton<bool>(
                          segments: const [
                            ButtonSegment(value: false, label: Text('すべての候補')),
                            ButtonSegment(value: true, label: Text('顔だけ')),
                          ],
                          selected: {_facesOnly},
                          onSelectionChanged: _busy
                              ? null
                              : (values) => setState(() {
                                  _facesOnly = values.single;
                                }),
                        ),
                        if (_facesOnly)
                          const Text('顔の候補だけを表示します。適用済みの黒塗りは保持します。'),
                        if (source != null) _faceControls(source),
                        _candidateControls(),
                        Wrap(
                          alignment: WrapAlignment.center,
                          children: [
                            TextButton(
                              onPressed: _busy || !_edits.canUndo
                                  ? null
                                  : () => setState(() {
                                      _edits.undo();
                                      _drag = null;
                                      _start = null;
                                    }),
                              child: const Text('取り消す'),
                            ),
                            TextButton(
                              onPressed:
                                  _busy ||
                                      (_redactions.isEmpty && !_edits.canUndo)
                                  ? null
                                  : () => setState(() {
                                      _selectedCandidates.clear();
                                      _edits.reset();
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

  Widget _faceControls(SourcePhoto source) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(switch (_faces.status) {
        FaceDetectionStatus.idle => '顔検出を準備しています',
        FaceDetectionStatus.detecting => '顔を検出中（手動編集・保存できます）',
        FaceDetectionStatus.ready =>
          _faces.candidates.isEmpty
              ? '顔の候補は見つかりませんでした'
              : '顔の候補 ${_faces.candidates.length}件',
        FaceDetectionStatus.failed => '顔検出を利用できませんでした。手動編集できます。',
        FaceDetectionStatus.cancelled => '顔検出を中止しました',
      }),
      const Text('検出で安全を完全に保証できません。隠し忘れを確認してください。'),
      if (_faces.canRetry)
        TextButton(
          onPressed: _busy || _covered ? null : () => _faces.detect(source),
          child: const Text('顔検出を再試行'),
        ),
      if (_faces.candidates.isNotEmpty)
        SizedBox(
          height: 96,
          child: ListView.builder(
            itemCount: _faces.candidates.length,
            itemBuilder: (context, index) {
              final candidate = _faces.candidates[index];
              final applied = _edits.isApplied(candidate.id);
              return TextButton(
                key: ValueKey('face-${candidate.id}'),
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _pointer = null;
                        _drag = null;
                        _start = null;
                        _edits.toggle(candidate);
                      }),
                child: Text('顔 ${index + 1}：${applied ? '解除' : '適用'}'),
              );
            },
          ),
        ),
    ],
  );

  Future<void> _openSettings() async {
    try {
      await const MethodChannel('dev.camereon/app_settings')
          .invokeMethod<void>('open');
    } catch (_) {
      // 権限エラーと編集状態を残し、再試行できるようにする。
    }
  }

  void _tapCandidate(Offset point, double scale) {
    // The smallest containing box wins, so a face/PC inside a person can be
    // selected directly. A frame edge wins over a containing box's interior.
    // Numbered controls remain available for exactly coincident candidates.
    final hits = <({HideRegion region, VoidCallback toggle})>[
      for (final face in _faces.candidates)
        (
          region: face.region,
          toggle: () => setState(() => _edits.toggle(face)),
        ),
      for (final candidate in _visibleCandidates)
        (region: candidate.region, toggle: () => _toggleCandidate(candidate)),
    ];
    final tolerance = 8 / scale;
    double edgeDistance(HideRegion region) {
      final rect = region.toRect();
      return [
        (point.dx - rect.left).abs(),
        (point.dx - rect.right).abs(),
        (point.dy - rect.top).abs(),
        (point.dy - rect.bottom).abs(),
      ].reduce(math.min);
    }

    hits.removeWhere(
      (hit) => !hit.region.toRect().inflate(tolerance).contains(point),
    );
    // Stable tie breaking keeps coincident face/person boxes predictable.
    var best = -1;
    for (var i = 0; i < hits.length; i++) {
      if (best == -1) {
        best = i;
        continue;
      }
      final a = hits[i].region;
      final b = hits[best].region;
      final aEdge = edgeDistance(a) <= tolerance;
      final bEdge = edgeDistance(b) <= tolerance;
      if ((aEdge && !bEdge) ||
          (aEdge == bEdge && a.width * a.height < b.width * b.height)) {
        best = i;
      }
    }
    if (best >= 0) hits[best].toggle();
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
            _pointerStart = event.localPosition;
            _dragging = false;
            _drag = null;
          });
        },
        onPointerMove: (event) {
          final start = _start;
          if (_busy || _pointer != event.pointer || start == null) return;
          if (!_dragging &&
              (event.localPosition - _pointerStart!).distance <= kTouchSlop) {
            return;
          }
          _dragging = true;
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
          if (!_dragging && !_busy && rect.contains(event.localPosition)) {
            _tapCandidate(pixel(event.localPosition), scale);
          }
          setState(() {
            if (_drag != null && !_busy) _edits.addManual(_drag!);
            _pointer = null;
            _drag = null;
            _start = null;
            _pointerStart = null;
            _dragging = false;
          });
        },
        onPointerCancel: (event) {
          if (_pointer != event.pointer) return;
          setState(() {
            _pointer = null;
            _drag = null;
            _start = null;
            _pointerStart = null;
            _dragging = false;
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
                    regions: List.unmodifiable([..._redactions, ?_drag]),
                    imageWidth: source.width,
                    imageHeight: source.height,
                  ),
                ),
              ),
            ),
            Positioned.fromRect(
              rect: rect,
              child: IgnorePointer(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    CustomPaint(
                      painter: FaceCandidatePainter(
                        candidates: _faces.candidates,
                        applied: {
                          for (final c in _faces.candidates)
                            if (_edits.isApplied(c.id)) c.id,
                        },
                        imageWidth: source.width,
                        imageHeight: source.height,
                      ),
                    ),
                    CandidateOverlay(
                      candidates: _visibleCandidates,
                      selectedRegions: Set.unmodifiable(
                        _selectedCandidateRegions,
                      ),
                      imageWidth: source.width,
                      imageHeight: source.height,
                    ),
                  ],
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

/// Faces and other detector candidates share the same drawing/coordinate code.
/// The prefix keeps face numbering distinct from text/person/screen numbering.
class FaceCandidatePainter extends CandidatePainter {
  FaceCandidatePainter({
    required List<FaceCandidate> candidates,
    required Set<String> applied,
    required int imageWidth,
    required int imageHeight,
  }) : super(
         [
           for (final c in candidates)
             RegionCandidate(kind: CandidateKind.face, region: c.region),
         ],
         imageWidth,
         imageHeight,
         {
           for (final c in candidates)
             if (applied.contains(c.id)) c.region,
         },
         labels: [for (var i = 0; i < candidates.length; i++) '顔${i + 1}'],
       );
}
