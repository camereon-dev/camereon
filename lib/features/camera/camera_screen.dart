import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'captured_photo_screen.dart';

enum _CameraIssue { permissionDenied, noCamera, failed }

const _appSettings = MethodChannel('dev.camereon/app_settings');

/// 起動直後に表示するカメラ画面。開いたらすぐにプレビューを始めて撮影できる。
class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  List<CameraDescription> _cameras = const [];
  CameraDescription? _selected;
  CameraController? _controller;
  _CameraIssue? _issue;
  bool _isCapturing = false;

  // カメラを開く・閉じるたびに進める。古い起動処理の結果を捨てるために使う。
  int _session = 0;
  // カメラの起動と解放は重ねると失敗するため、順番に実行する
  Future<void> _cameraTask = Future.value();
  bool _closedInBackground = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _openCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session++;
    _disposeController(_controller);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      // 権限ダイアログでも inactive・resumed になるため、
      // 画面が隠れたときだけ解放し、戻ってきたら開き直す
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!_closedInBackground) _closeCamera();
      case AppLifecycleState.resumed:
        if (_closedInBackground) _openCamera();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _disposeController(CameraController? controller) {
    if (controller == null) return;
    _cameraTask = _cameraTask.then((_) => controller.dispose()).catchError((
      Object e,
    ) {
      debugPrint('camera: failed to dispose: $e');
    });
  }

  void _closeCamera() {
    _session++;
    _closedInBackground = true;
    final controller = _controller;
    setState(() => _controller = null);
    _disposeController(controller);
  }

  void _openCamera() {
    final session = ++_session;
    _closedInBackground = false;
    final previous = _controller;
    setState(() {
      _controller = null;
      _issue = null;
    });
    _disposeController(previous);
    _cameraTask = _cameraTask.then((_) => _startCamera(session));
  }

  Future<void> _startCamera(int session) async {
    if (session != _session) return;

    CameraController? controller;
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      if (session != _session) return;
      if (_cameras.isEmpty) {
        setState(() => _issue = _CameraIssue.noCamera);
        return;
      }

      final description = _selected ??= _cameras.firstWhere(
        (camera) => camera.lensDirection == CameraLensDirection.back,
        orElse: () => _cameras.first,
      );
      controller = CameraController(
        description,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      // 画面は縦向き固定。端末を傾けてもプレビューが回転しないようにする
      await controller.lockCaptureOrientation(DeviceOrientation.portraitUp);
      if (session != _session) {
        await controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (e) {
      debugPrint('camera: failed to open: $e');
      try {
        await controller?.dispose();
      } catch (_) {
        // 起動に失敗したカメラの解放エラーは表示に影響しないため無視する
      }
      if (session != _session) return;
      setState(() {
        _issue = e is CameraException && e.code == 'CameraAccessDenied'
            ? _CameraIssue.permissionDenied
            : _CameraIssue.failed;
      });
    }
  }

  bool get _canSwitchCamera =>
      _cameras.map((camera) => camera.lensDirection).toSet().length > 1;

  void _switchCamera() {
    final current = _selected;
    if (current == null || !_canSwitchCamera || _isCapturing) return;
    _selected = _cameras.firstWhere(
      (camera) => camera.lensDirection != current.lensDirection,
    );
    _openCamera();
  }

  Future<void> _takePicture() async {
    final controller = _controller;
    if (controller == null || _isCapturing) return;

    setState(() => _isCapturing = true);
    try {
      // カメラが応答しなくなっても撮影ボタンが押せないままにならないようにする
      final photo = await controller.takePicture().timeout(
        const Duration(seconds: 10),
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => CapturedPhotoScreen(photo: photo),
        ),
      );
    } catch (e) {
      debugPrint('camera: failed to take picture: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('撮影できませんでした。もう一度お試しください。')));
      if (e is TimeoutException) _openCamera();
    } finally {
      if (mounted) setState(() => _isCapturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final issue = _issue;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: issue != null
                    ? _CameraMessage(issue: issue, onRetry: _openCamera)
                    : controller == null
                    ? const SizedBox.expand()
                    : _Preview(controller: controller),
              ),
              _ControlBar(
                canShoot: controller != null && !_isCapturing,
                canSwitch: issue == null && _canSwitchCamera && !_isCapturing,
                onShoot: _takePicture,
                onSwitch: _switchCamera,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Preview extends StatelessWidget {
  const _Preview({required this.controller});

  final CameraController controller;

  @override
  Widget build(BuildContext context) {
    // 撮影される範囲をそのまま見せるため、プレビューは切り取らずに収める
    return Align(
      alignment: Alignment.topCenter,
      child: AspectRatio(
        aspectRatio: 1 / controller.value.aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: controller.buildPreview(),
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.canShoot,
    required this.canSwitch,
    required this.onShoot,
    required this.onSwitch,
  });

  final bool canShoot;
  final bool canSwitch;
  final VoidCallback onShoot;
  final VoidCallback onSwitch;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 20, 32, 28),
      child: Row(
        children: [
          const Expanded(child: SizedBox()),
          _ShutterButton(onPressed: canShoot ? onShoot : null),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: IconButton.filledTonal(
                onPressed: canSwitch ? onSwitch : null,
                iconSize: 28,
                padding: const EdgeInsets.all(12),
                tooltip: 'カメラを切り替える',
                icon: const Icon(Icons.cameraswitch_rounded),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.onPressed});

  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: '撮影する',
      child: GestureDetector(
        onTap: onPressed,
        child: AnimatedOpacity(
          opacity: enabled ? 1 : 0.4,
          duration: const Duration(milliseconds: 150),
          child: Container(
            width: 78,
            height: 78,
            padding: const EdgeInsets.all(5),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 4),
            ),
            child: const DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CameraMessage extends StatelessWidget {
  const _CameraMessage({required this.issue, required this.onRetry});

  final _CameraIssue issue;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (icon, title, body) = switch (issue) {
      _CameraIssue.permissionDenied => (
        Icons.no_photography_rounded,
        'カメラの使用が許可されていません',
        '撮影するには、カメラへのアクセスを許可してください。'
            '許可を求める画面が出ない場合は、設定から許可できます。',
      ),
      _CameraIssue.noCamera => (
        Icons.videocam_off_rounded,
        'カメラが見つかりません',
        'この端末で使えるカメラがありません。',
      ),
      _CameraIssue.failed => (
        Icons.error_outline_rounded,
        'カメラを起動できませんでした',
        '他のアプリがカメラを使っていないか確認して、もう一度お試しください。',
      ),
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(
        children: [
          const SizedBox(height: 48),
          Icon(icon, size: 48, color: Colors.white70),
          const SizedBox(height: 20),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            body,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: Colors.white70,
              height: 1.6,
            ),
          ),
          if (issue != _CameraIssue.noCamera) ...[
            const SizedBox(height: 28),
            FilledButton(
              onPressed: onRetry,
              child: Text(
                issue == _CameraIssue.permissionDenied ? '許可する' : 'もう一度試す',
              ),
            ),
          ],
          if (issue == _CameraIssue.permissionDenied) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => _appSettings.invokeMethod<void>('open'),
              child: const Text('設定を開く'),
            ),
          ],
        ],
      ),
    );
  }
}
