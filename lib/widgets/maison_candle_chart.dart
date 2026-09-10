import 'package:flutter/material.dart';
import '../models/candlestick.dart';

/// Maison quotation-board candle chart.
///
/// Candle law (see `references/chart-doctrine.md` in fuego-maison-brand):
/// rising = Champagne Gold filled, falling = hollow (Muted Gold border).
/// Filled-vs-hollow passes the B&W test by construction — no green, no red.
class MaisonCandleChart extends StatefulWidget {
  final List<Candlestick> candles;
  final Color upColor;
  final Color downColor;
  final Color gridColor;
  final Color textColor;
  final int maxVisible;

  const MaisonCandleChart({
    super.key,
    required this.candles,
    this.upColor = const Color(0xFFC5A059),
    this.downColor = const Color(0xFF8C734B),
    this.gridColor = const Color(0x148C734B),
    this.textColor = const Color(0xFF8A8278),
    this.maxVisible = 120,
  });

  @override
  State<MaisonCandleChart> createState() => _MaisonCandleChartState();
}

class _MaisonCandleChartState extends State<MaisonCandleChart> {
  Offset? _touch;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanDown: (d) => setState(() => _touch = d.localPosition),
      onPanUpdate: (d) => setState(() => _touch = d.localPosition),
      onPanEnd: (_) => setState(() => _touch = null),
      onPanCancel: () => setState(() => _touch = null),
      child: CustomPaint(
        painter: _CandlePainter(
          candles: widget.candles.length > widget.maxVisible
              ? widget.candles.sublist(widget.candles.length - widget.maxVisible)
              : widget.candles,
          upColor: widget.upColor,
          downColor: widget.downColor,
          gridColor: widget.gridColor,
          textColor: widget.textColor,
          touch: _touch,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _CandlePainter extends CustomPainter {
  final List<Candlestick> candles;
  final Color upColor;
  final Color downColor;
  final Color gridColor;
  final Color textColor;
  final Offset? touch;

  _CandlePainter({
    required this.candles,
    required this.upColor,
    required this.downColor,
    required this.gridColor,
    required this.textColor,
    required this.touch,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.isEmpty) return;

    const labelW = 52.0;
    const volH = 0.20; // volume strip fraction
    final plotW = size.width - labelW;
    final priceH = size.height * (1 - volH) - 8;
    final volTop = size.height * (1 - volH);

    double lo = candles.first.low, hi = candles.first.high, volMax = 0;
    for (final c in candles) {
      if (c.low < lo) lo = c.low;
      if (c.high > hi) hi = c.high;
      if (c.volume > volMax) volMax = c.volume;
    }
    if ((hi - lo).abs() < 1e-12) {
      hi = lo + 1;
    }
    final pad = (hi - lo) * 0.08;
    hi += pad;
    lo -= pad;

    double py(double p) => priceH - (p - lo) / (hi - lo) * priceH;

    // Grid — three quiet lines.
    final grid = Paint()..color = gridColor..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = priceH * (i + 1) / 4;
      canvas.drawLine(Offset(0, y), Offset(plotW, y), grid);
    }

    final slot = plotW / candles.length;
    final bodyW = (slot * 0.6).clamp(1.5, 14.0);
    final upFill = Paint()..color = upColor..style = PaintingStyle.fill;
    final upWick = Paint()
      ..color = upColor
      ..strokeWidth = 1;
    final downBorder = Paint()
      ..color = downColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final downWick = Paint()
      ..color = downColor
      ..strokeWidth = 1;
    final volUp = Paint()..color = upColor.withValues(alpha: 0.35);
    final volDown = Paint()..color = downColor.withValues(alpha: 0.35);

    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final x = slot * i + slot / 2;
      final up = c.close >= c.open;
      // Wick.
      canvas.drawLine(
          Offset(x, py(c.high)), Offset(x, py(c.low)), up ? upWick : downWick);
      // Body.
      final top = py(up ? c.close : c.open);
      final bottom = py(up ? c.open : c.close);
      final rect = Rect.fromLTRB(
          x - bodyW / 2, top, x + bodyW / 2, (bottom - top).abs() < 1 ? top + 1 : bottom);
      if (up) {
        canvas.drawRect(rect, upFill);
      } else {
        canvas.drawRect(rect, downBorder);
      }
      // Volume.
      if (volMax > 0 && c.volume > 0) {
        final vh = (c.volume / volMax) * (size.height - volTop - 2);
        canvas.drawRect(
          Rect.fromLTRB(x - bodyW / 2, size.height - vh, x + bodyW / 2, size.height),
          up ? volUp : volDown,
        );
      }
    }

    // Last-price dashed line + pill.
    final last = candles.last.close;
    final ly = py(last).clamp(0.0, priceH);
    final dash = Paint()
      ..color = upColor
      ..strokeWidth = 1;
    const step = 5.0, gap = 4.0;
    for (var x = 0.0; x < plotW; x += step + gap) {
      canvas.drawLine(Offset(x, ly), Offset((x + step).clamp(0, plotW), ly), dash);
    }
    _pill(canvas, _fmt(last), plotW + 2, ly, labelW - 4, upColor);

    // Min/max labels.
    _pill(canvas, _fmt(hi - pad), plotW + 2, 8, labelW - 4, textColor);
    _pill(canvas, _fmt(lo + pad), plotW + 2, priceH - 8, labelW - 4, textColor);

    // Crosshair on touch.
    if (touch != null && touch!.dx >= 0 && touch!.dx <= plotW) {
      final cross = Paint()
        ..color = upColor.withValues(alpha: 0.7)
        ..strokeWidth = 1;
      canvas.drawLine(Offset(touch!.dx, 0), Offset(touch!.dx, size.height), cross);
      final ty = touch!.dy.clamp(0.0, priceH);
      canvas.drawLine(Offset(0, ty), Offset(plotW, ty), cross);
      final price = hi - (ty / priceH) * (hi - lo);
      _pill(canvas, _fmt(price), plotW + 2, ty, labelW - 4, upColor);

      // OHLC readout of the touched candle.
      final idx = (touch!.dx / slot).floor().clamp(0, candles.length - 1);
      final c = candles[idx];
      _text(
        canvas,
        'O ${_fmt(c.open)}  H ${_fmt(c.high)}  L ${_fmt(c.low)}  C ${_fmt(c.close)}',
        const Offset(6, 4),
        textColor,
        10,
      );
    }
  }

  String _fmt(double v) {
    if (v >= 1000) return v.toStringAsFixed(2);
    if (v >= 1) return v.toStringAsFixed(4);
    return v.toStringAsFixed(6);
  }

  void _pill(Canvas canvas, String s, double x, double y, double w, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontFamily: 'IBMPlexMono',
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);
    final cy = (y - 8).clamp(0.0, double.infinity);
    tp.paint(canvas, Offset(x, cy));
  }

  void _text(Canvas canvas, String s, Offset at, Color color, double size) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          color: color,
          fontSize: size,
          fontFamily: 'IBMPlexMono',
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) =>
      old.candles != candles || old.touch != touch;
}
