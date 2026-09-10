import 'package:flutter/material.dart';
import '../models/candlestick.dart';
import 'maison_candle_chart.dart';

/// House quotation-board chart. Maison candle law: rising = Champagne Gold
/// filled, falling = hollow Muted Gold. See chart-doctrine.md.
class FuegoChart extends StatelessWidget {
  final List<Candlestick> candles;
  final String pair;
  final Color lineColor;
  final Color bgColor;

  const FuegoChart({
    super.key,
    required this.candles,
    this.pair = '',
    this.lineColor = const Color(0xFFC5A059),
    this.bgColor = const Color(0xFF0D0B08),
  });

  @override
  Widget build(BuildContext context) {
    if (candles.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, constraints) {
      final height = constraints.maxHeight;
      final width = constraints.maxWidth;
      if (height <= 0 || width <= 0) return const SizedBox.shrink();
      return Container(
        height: height,
        width: width,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(0),
        ),
        clipBehavior: Clip.hardEdge,
        child: Stack(
          children: [
            MaisonCandleChart(
              candles: candles,
              upColor: lineColor,
            ),
            if (pair.isNotEmpty)
              Positioned(
                top: 8,
                left: 12,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: bgColor.withValues(alpha: 0.78),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(pair,
                      style: TextStyle(
                          color: lineColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2)),
                ),
              ),
          ],
        ),
      );
    });
  }
}
