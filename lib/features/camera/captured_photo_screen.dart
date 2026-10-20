import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'; // kIsWeb を利用するために追加
import 'package:flutter/material.dart';

/// 撮影した写真の確認画面。ドラッグによる複数領域の黒塗り選択をサポート。
class CapturedPhotoScreen extends StatefulWidget {
  const CapturedPhotoScreen({super.key, required this.photo});

  final XFile photo;

  @override
  State<CapturedPhotoScreen> createState() => _CapturedPhotoScreenState();
}

class _CapturedPhotoScreenState extends State<CapturedPhotoScreen> {
  // ドラッグ開始位置
  Offset? _startPoint;
  // 現在ドラッグ中の選択領域
  Rect? _currentSelection;
  // 確定した黒塗り領域のリスト
  final List<Rect> _selectedRects = [];

  @override
  void dispose() {
    // Web環境以外の場合のみ、一時ファイルを削除する
    if (!kIsWeb) {
      File(widget.photo.path).delete().ignore();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: GestureDetector(
                    onPanStart: (details) {
                      setState(() {
                        _startPoint = details.localPosition;
                        _currentSelection =
                            Rect.fromPoints(_startPoint!, _startPoint!);
                      });
                    },
                    onPanUpdate: (details) {
                      if (_startPoint == null) return;
                      setState(() {
                        _currentSelection = Rect.fromPoints(
                            _startPoint!, details.localPosition);
                      });
                    },
                    onPanEnd: (details) {
                      if (_currentSelection != null) {
                        setState(() {
                          _selectedRects.add(_currentSelection!);
                          _currentSelection = null;
                          _startPoint = null;
                        });
                      }
                    },
                    child: Stack(
                      children: [
                        // 下層：画像表示（Web環境ではダミー画像、実機環境では撮影写真）
                        kIsWeb
                            ? Image.network(
                                'https://picsum.photos/400/500',
                                fit: BoxFit.contain,
                                semanticLabel: '撮影した写真（ダミー）',
                              )
                            : Image.file(
                                File(widget.photo.path),
                                fit: BoxFit.contain,
                                semanticLabel: '撮影した写真',
                              ),
                        // 上層：黒塗り描画レイヤー
                        Positioned.fill(
                          child: CustomPaint(
                            painter: SelectionPainter(
                              selectedRects: _selectedRects,
                              currentSelection: _currentSelection,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => Navigator.of(context).pop(),
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(52),
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.replay_rounded),
                          label: const Text('撮り直す'),
                        ),
                      ),
                      if (_selectedRects.isNotEmpty) ...[
                        const SizedBox(width: 12),
                        IconButton(
                          onPressed: () {
                            setState(() {
                              _selectedRects.clear();
                            });
                          },
                          icon: const Icon(Icons.undo, color: Colors.white),
                          tooltip: '選択をクリア',
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    _selectedRects.isEmpty
                        ? '画像上をドラッグして黒塗り範囲を選択してください'
                        : '${_selectedRects.length}箇所の領域を選択中',
                    textAlign: TextAlign.center,
                    style:
                        const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 選択領域（確定した黒塗り＋ドラッグ中のプレビュー）を描画するペインター
class SelectionPainter extends CustomPainter {
  SelectionPainter({
    required this.selectedRects,
    this.currentSelection,
  });

  final List<Rect> selectedRects;
  final Rect? currentSelection;

  @override
  void paint(Canvas canvas, Size size) {
    // 確定済みの黒塗り描画
    final blackPaint = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.fill;

    for (final rect in selectedRects) {
      canvas.drawRect(rect, blackPaint);
    }

    // 現在ドラッグ中の選択枠（赤枠ガイド）描画
    if (currentSelection != null) {
      final borderPaint = Paint()
        ..color = Colors.redAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      final fillPaint = Paint()
        ..color = Colors.black.withOpacity(0.5)
        ..style = PaintingStyle.fill;

      canvas.drawRect(currentSelection!, fillPaint);
      canvas.drawRect(currentSelection!, borderPaint);
    }
  }

  @override
  bool shouldRepaint(covariant SelectionPainter oldDelegate) {
    return oldDelegate.selectedRects != selectedRects ||
        oldDelegate.currentSelection != currentSelection;
  }
}
