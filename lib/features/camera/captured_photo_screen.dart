import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

/// 撮影した写真の確認画面。隠す・保存は次の段階で追加する。
class CapturedPhotoScreen extends StatefulWidget {
  const CapturedPhotoScreen({super.key, required this.photo});

  final XFile photo;

  @override
  State<CapturedPhotoScreen> createState() => _CapturedPhotoScreenState();
}

class _CapturedPhotoScreenState extends State<CapturedPhotoScreen> {
  @override
  void dispose() {
    // 未加工の写真はアプリの一時ファイルにだけ置き、画面を閉じたら消す
    File(widget.photo.path).delete().ignore();
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
                  child: Image.file(
                    File(widget.photo.path),
                    fit: BoxFit.contain,
                    semanticLabel: '撮影した写真',
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 28),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => Navigator.of(context).pop(),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(52),
                      foregroundColor: Colors.white,
                    ),
                    icon: const Icon(Icons.replay_rounded),
                    label: const Text('撮り直す'),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '隠す・保存する機能は今後追加予定です',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white60, fontSize: 12),
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
