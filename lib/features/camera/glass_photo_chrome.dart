import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const glassMint = Color(0xFFBDFCE8);

/// Bounded blur: only the floating controls sample the photograph behind them.
class PhotoGlass extends StatelessWidget {
  const PhotoGlass({super.key, required this.child, this.radius = 32});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Colors.white.withValues(alpha: .16),
              const Color(0xB31B2328),
            ],
          ),
          border: Border.all(color: Colors.white.withValues(alpha: .22)),
        ),
        child: Material(color: Colors.transparent, child: child),
      ),
    ),
  );
}

class GlassIconButton extends StatelessWidget {
  const GlassIconButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.primary = false,
  });
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    onPressed: onPressed,
    style: IconButton.styleFrom(
      minimumSize: const Size(48, 48),
      backgroundColor: primary ? glassMint : Colors.transparent,
      foregroundColor: primary ? const Color(0xFF142A25) : Colors.white,
      disabledForegroundColor: Colors.white30,
    ),
    icon: Icon(icon, size: 22),
  );
}

/// A translucent light sheet sweeps only while a real detector is working.
class PhotoScanEffect extends StatefulWidget {
  const PhotoScanEffect({super.key, required this.active});
  final bool active;
  @override
  State<PhotoScanEffect> createState() => _PhotoScanEffectState();
}

class _PhotoScanEffectState extends State<PhotoScanEffect>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  void _sync() {
    if (widget.active && !MediaQuery.disableAnimationsOf(context)) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(PhotoScanEffect oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: AnimatedOpacity(
      opacity: widget.active ? 1 : 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 320),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          painter: _ScanPainter(
            MediaQuery.disableAnimationsOf(context) ? .5 : _controller.value,
          ),
        ),
      ),
    ),
  );
}

class _ScanPainter extends CustomPainter {
  _ScanPainter(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);
    final y = (size.height + 240) * progress - 120;
    final sheet = Rect.fromLTWH(0, y - 140, size.width, 140);
    canvas.drawRect(
      sheet,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            glassMint.withValues(alpha: 0),
            glassMint.withValues(alpha: .13),
          ],
        ).createShader(sheet),
    );
    final glow = Paint()
      ..color = glassMint.withValues(alpha: .65)
      ..strokeWidth = 2
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9);
    canvas.drawLine(Offset(0, y), Offset(size.width, y), glow);
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..shader = LinearGradient(
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: .8),
            Colors.white.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromLTWH(0, y - 1, size.width, 2))
        ..strokeWidth = .8,
    );
  }

  @override
  bool shouldRepaint(_ScanPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
