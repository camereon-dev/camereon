import 'package:flutter/material.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _showAbout(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('camereon について'),
        content: const Text(
          '写真に写り込んだ個人情報を、投稿する前に隠せるカメラアプリです。'
          '\n\n撮影・編集・保存の機能は今後追加予定です。'
          '\n\n隠し忘れがないか、ご自身でも確認してください。'
          '安全を完全に保証するものではありません。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('閉じる'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 28,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.camera_rounded, color: colors.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'camereon',
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 36),
                    const _PhotoIllustration(),
                    const SizedBox(height: 32),
                    Text(
                      '写真を、安心して\nシェアするために。',
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        height: 1.45,
                        color: const Color(0xFF173C2C),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '写り込んだ情報を、投稿する前に。\n気になる場所を隠して、写真を楽しもう。',
                      style: theme.textTheme.bodyLarge?.copyWith(
                        height: 1.7,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Wrap(
                      spacing: 20,
                      runSpacing: 12,
                      children: [
                        _Step(number: '01', label: '撮る'),
                        _Step(number: '02', label: '隠す'),
                        _Step(number: '03', label: '保存する'),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF1E7),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.phonelink_lock_rounded,
                            color: colors.primary,
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'あなたの写真は、あなたの端末で。\n画像を無断で外部に送信しません。',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                height: 1.6,
                                color: colors.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: () => _showAbout(context),
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: const Text('このアプリについて'),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '撮影・編集機能は今後追加予定です',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.label});

  final String number;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          number,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: theme.textTheme.labelLarge),
      ],
    );
  }
}

class _PhotoIllustration extends StatelessWidget {
  const _PhotoIllustration();

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: Container(
        height: 190,
        decoration: BoxDecoration(
          color: const Color(0xFFE4EDDF),
          borderRadius: BorderRadius.circular(28),
        ),
        child: Center(
          child: Transform.rotate(
            angle: -0.06,
            child: Container(
              width: 218,
              height: 145,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x14235C43),
                    blurRadius: 16,
                    offset: Offset(0, 8),
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFFF0F4E9),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.landscape_rounded,
                        color: Color(0xFF92AA80),
                        size: 106,
                      ),
                    ),
                  ),
                  Positioned(
                    right: 14,
                    bottom: 14,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF235C43),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Icon(
                        Icons.visibility_off_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
