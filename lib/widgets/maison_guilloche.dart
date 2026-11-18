import 'package:flutter/material.dart';

/// Engine-turned guilloché texture: fine concentric ring sets from two
/// off-canvas centres, evoking a hand-lacquered watch dial at ~3% ink.
///
/// Shared by the XFG dial and every portfolio stratum so the home page reads
/// as one case rather than a stack of unrelated cards.
class MaisonGuillochePainter extends CustomPainter {
  const MaisonGuillochePainter({this.ink = 0.035, this.goldInk = 0.06});

  final double ink;
  final double goldInk;

  @override
  void paint(Canvas canvas, Size size) {
    final white = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.6
      ..color = Colors.white.withValues(alpha: ink);
    final gold = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.7
      ..shader = const LinearGradient(
        colors: [
          Color(0xFF8C734B),
          Color(0xFFC5A059),
          Color(0xFFD4B896),
          Color(0xFF8C734B),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
      ..color = const Color(0xFFC5A059).withValues(alpha: goldInk);

    void rings(Offset center, int count, double step, Paint paint) {
      for (var i = 1; i <= count; i++) {
        canvas.drawCircle(center, i * step, paint);
      }
    }

    rings(Offset(size.width * 0.88, -size.height * 0.30), 26, 15, white);
    rings(const Offset(-30, 0), 14, 17, white);
    rings(Offset(size.width * 0.88, -size.height * 0.30), 9, 42, gold);
  }

  @override
  bool shouldRepaint(covariant MaisonGuillochePainter oldDelegate) =>
      oldDelegate.ink != ink || oldDelegate.goldInk != goldInk;
}
