import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/analysis/analysis_services.dart';
import '../../core/analysis/scene_analysis.dart';
import 'prepare_analysis_image.dart';

class PhotoAnalysisScreen extends StatefulWidget {
  const PhotoAnalysisScreen({
    super.key,
    required this.loadImage,
    this.services,
  });
  final Future<Uint8List> Function() loadImage;
  final AnalysisServices? services;

  @override
  State<PhotoAnalysisScreen> createState() => _PhotoAnalysisScreenState();
}

class _PhotoAnalysisScreenState extends State<PhotoAnalysisScreen> {
  late final services = widget.services ?? AnalysisServices.instance;
  AnalysisImage? _image;
  bool _ready = false;
  bool _checking = true;
  bool _downloading = false;
  bool _running = false;
  bool _deleting = false;
  bool _cancelling = false;
  int _received = 0;
  int _total = 0;
  String? _notice;
  String _text = '';
  AnalysisPhase _phase = AnalysisPhase.loadingModel;
  AnalysisBackend _backend = AnalysisBackend.automatic;
  SceneDescription? _result;

  bool get _working => _checking || _downloading || _running || _deleting;

  @override
  void initState() {
    super.initState();
    unawaited(_prepare());
  }

  Future<void> _prepare() async {
    try {
      final image = await prepareAnalysisImage(await widget.loadImage());
      if (!mounted) return;
      setState(() => _image = image);
      final ready =
          services.analyzer.isSupported && await services.models.isReady();
      if (mounted) setState(() => _ready = ready);
    } catch (_) {
      if (mounted) {
        setState(() => _notice = '写真またはモデルを確認できませんでした。画面を開き直してください。');
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _message(Object error) {
    if (error is AnalysisCancelled) return '中止しました。';
    if (error is! AnalysisFailure) return '処理を完了できませんでした。もう一度お試しください。';
    return switch (error.kind) {
      AnalysisFailureKind.unsupported =>
        'この端末は写真の解析に対応していません。Android 11 以上・ARM64 の端末が必要です。',
      AnalysisFailureKind.busy => '前の処理を終了しています。少し待ってからお試しください。',
      AnalysisFailureKind.missingModel =>
        '解析用データを確認できませんでした。削除して、もう一度準備してください。',
      AnalysisFailureKind.storage => '空き容量が不足しています。約4.8GB以上の空きを確保してからお試しください。',
      AnalysisFailureKind.network => 'ダウンロードできませんでした。通信状態を確認して、もう一度お試しください。',
      AnalysisFailureKind.integrity => '取得したデータを確認できませんでした。もう一度ダウンロードしてください。',
      AnalysisFailureKind.inference =>
        '解析を完了できませんでした。ほかのアプリを閉じるか、互換モードでお試しください。',
    };
  }

  Future<void> _download() async {
    setState(() {
      _downloading = true;
      _notice = null;
      _received = 0;
      _total = 0;
    });
    try {
      await services.models.download(
        onProgress: (received, total) {
          if (mounted) {
            setState(() {
              _received = received;
              _total = total;
            });
          }
        },
      );
      if (mounted) {
        setState(() {
          _ready = true;
          _notice = '解析用データの準備ができました。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _notice = _message(error));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<void> _analyze() async {
    final image = _image;
    if (image == null) return;
    if (services.analyzer.isBusy) {
      setState(
        () =>
            _notice = _message(const AnalysisFailure(AnalysisFailureKind.busy)),
      );
      return;
    }
    setState(() {
      _running = true;
      _cancelling = false;
      _notice = null;
      _text = '';
      _result = null;
    });
    try {
      final result = await services.analyzer.describe(
        image,
        backend: _backend,
        onPhase: (phase) {
          if (mounted) setState(() => _phase = phase);
        },
        onText: (text) {
          if (mounted && !_cancelling) setState(() => _text = text);
        },
      );
      if (mounted) {
        setState(() {
          _result = result;
          _text = result.text;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _notice = _message(error);
          _text = '';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _running = false;
          _cancelling = false;
        });
      }
    }
  }

  Future<void> _cancelAnalysis() async {
    setState(() => _cancelling = true);
    await services.analyzer.cancel();
  }

  Future<void> _deleteModel() async {
    if (services.analyzer.isBusy) {
      setState(
        () =>
            _notice = _message(const AnalysisFailure(AnalysisFailureKind.busy)),
      );
      return;
    }
    setState(() {
      _deleting = true;
      _notice = null;
    });
    try {
      await services.models.delete();
      if (mounted) {
        setState(() {
          _ready = false;
          _notice = '解析用データを削除しました。';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _notice = _message(error));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  void dispose() {
    if (_downloading) services.models.cancelDownload();
    if (_running) unawaited(services.analyzer.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final supported = services.analyzer.isSupported;
    final result = _result;
    return Scaffold(
      appBar: AppBar(title: const Text('写真の内容を確認')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(
                  image.bytes,
                  height: 200,
                  fit: BoxFit.contain,
                  semanticLabel: '解析する写真',
                ),
              ),
            const SizedBox(height: 16),
            Text(
              '端末内の AI が写真の内容を説明します。',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text('見落としや誤りがあります。投稿前に、ご自身でも写真を確認してください。'),
            const SizedBox(height: 16),
            if (!supported) const Text('写真の解析には Android 11 以上・ARM64 の端末が必要です。'),
            if (_checking) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              const Text('写真と解析用データを確認しています…'),
            ],
            if (supported && !_checking && !_ready) ...[
              const Text(
                '初回は Gemma 4 の解析用データ（約2.6GB）を取得します。写真は送信しません。Wi-Fi での準備をおすすめします。モデルと作業領域を含め約4.8GBの空き容量が必要です。',
              ),
              const SizedBox(height: 12),
              if (!_downloading)
                FilledButton.icon(
                  onPressed: _working ? null : _download,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('解析用データをダウンロード'),
                ),
            ],
            if (_downloading) ...[
              LinearProgressIndicator(
                value: _total > 0 ? _received / _total : null,
              ),
              const SizedBox(height: 8),
              Text(
                _total > 0 && _received == _total
                    ? '取得したデータを検証しています…'
                    : '${(_received / 1000000).toStringAsFixed(0)} MB を取得しました',
              ),
              OutlinedButton(
                onPressed: services.models.cancelDownload,
                child: const Text('準備を中止'),
              ),
            ],
            if (supported && _ready) ...[
              const Text('解析用データの準備済み。この写真は端末内で処理します。'),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _working || image == null ? null : _analyze,
                icon: const Icon(Icons.auto_awesome_rounded),
                label: Text(result == null ? '写真を解析する' : 'もう一度解析する'),
              ),
            ],
            if (_running) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                _cancelling
                    ? '解析を中止しています…'
                    : switch (_phase) {
                        AnalysisPhase.loadingModel =>
                          'AI を準備しています。初回は時間がかかることがあります…',
                        AnalysisPhase.describing => '写真の内容を確認しています…',
                        AnalysisPhase.releasing => '解析を終了しています…',
                      },
              ),
              OutlinedButton(
                onPressed: _cancelling ? null : _cancelAnalysis,
                child: const Text('解析を中止'),
              ),
            ],
            if (_notice != null) ...[
              const SizedBox(height: 16),
              Text(_notice!, semanticsLabel: _notice),
            ],
            if (_text.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                'AI の説明（参考）',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(_text),
            ],
            if (supported) ...[
              const SizedBox(height: 24),
              ExpansionTile(
                title: const Text('解析の設定'),
                tilePadding: EdgeInsets.zero,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('互換モード'),
                    subtitle: const Text(
                      '通常のモードで解析できないときに試してください。処理に時間がかかる場合があります。',
                    ),
                    value: _backend == AnalysisBackend.compatible,
                    onChanged: _working
                        ? null
                        : (value) => setState(
                            () => _backend = value
                                ? AnalysisBackend.compatible
                                : AnalysisBackend.automatic,
                          ),
                  ),
                  if (result != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '処理時間 ${result.totalTime.inMilliseconds / 1000} 秒 / 読み込み ${result.loadTime.inMilliseconds / 1000} 秒\n'
                        '実行方式 ${result.backend} / 画像 ${result.visionBackend}',
                      ),
                    ),
                  TextButton.icon(
                    onPressed: _working ? null : _deleteModel,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('解析用データを削除'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
