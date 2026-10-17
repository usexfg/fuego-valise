import 'package:flutter/material.dart';
import '../../utils/theme.dart';

class SuccessConfetti extends StatelessWidget {
  const SuccessConfetti({super.key});
  @override
  Widget build(BuildContext context) {
    final List<Color> colors = <Color>[
      AppTheme.primaryColor,
      AppTheme.successColor,
      AppTheme.warningColor,
      AppTheme.infoColor,
      AppTheme.accentColor,
      AppTheme.primaryLight,
    ];
    return IgnorePointer(
      child: Stack(
        children: <Widget>[
          for (int i = 0; i < 6; i++)
            _FallingDot(
              color: colors[i],
              left: 36.0 + i * 52.0,
              delayMs: i * 110,
            ),
        ],
      ),
    );
  }
}

class _FallingDot extends StatelessWidget {
  const _FallingDot({
    required this.color,
    required this.left,
    required this.delayMs,
  });
  final Color color;
  final double left;
  final int delayMs;
  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: -10, end: 340),
      duration: Duration(milliseconds: 1400 + delayMs),
      curve: Curves.easeInCubic,
      builder: (BuildContext context, double top, Widget? child) {
        return Positioned(left: left, top: top, child: child!);
      },
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
    );
  }
}

void showSuccessConfetti(BuildContext context) {
  final OverlayState overlay = Overlay.of(context);
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (BuildContext context) =>
        const Positioned.fill(child: SuccessConfetti()),
  );
  overlay.insert(entry);
  Future<void>.delayed(const Duration(seconds: 2), () {
    if (entry.mounted) {
      entry.remove();
    }
  });
}
