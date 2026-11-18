import 'package:flutter/material.dart';

import '../../models/candlestick.dart';
import 'trading_series.dart';
import 'trading_style.dart';

/// Quote row, timeframe chips, and a collapsible candle plot.
///
/// The series is whatever the caller passes. If it is historical rather than
/// a live feed, set [history] so the row says so instead of implying a market.
class TradingChart extends StatefulWidget {
  const TradingChart({
    super.key,
    required this.candles,
    this.symbol = 'XFG',
    this.quote = 'USD',
    this.history = true,
    this.loading = false,
    this.plotHeight = 168,
    this.initiallyOpen = true,
  });

  final List<Candlestick> candles;
  final String symbol;
  final String quote;
  final bool history;
  final bool loading;
  final double plotHeight;
  final bool initiallyOpen;

  @override
  State<TradingChart> createState() => _TradingChartState();
}

class _TradingChartState extends State<TradingChart> {
  TradingSpan _span = TradingSpan.year;
  late bool _open = widget.initiallyOpen;
  int? _pressed;

  List<Candlestick> get _window => TradingSeries.window(widget.candles, _span);

  @override
  Widget build(BuildContext context) {
    final window = _window;
    final move = TradingSeries.moveOf(window);
    final pressed = _pressed;
    final readout = pressed != null && pressed < window.length
        ? window[pressed]
        : null;
    final shown = readout?.close ?? move.close;
    final moveColor = move.up
        ? TradingStyle.gain
        : move.down
        ? TradingStyle.loss
        : TradingStyle.flat;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 44,
          child: Row(
            children: [
              Text(widget.symbol, style: TradingStyle.ticker()),
              const SizedBox(width: 6),
              Flexible(
                child: _quoteText(window, shown, move, moveColor, readout),
              ),
              const SizedBox(width: 6),
              if (widget.history && !widget.loading)
                Text('HISTORY', style: TradingStyle.caption(size: 9)),
              const SizedBox(width: 4),
              for (final span in TradingSpan.values) _chip(span),
              const SizedBox(width: 4),
              GestureDetector(
                onTap: () => setState(() => _open = !_open),
                behavior: HitTestBehavior.opaque,
                child: Icon(
                  _open ? Icons.expand_less : Icons.expand_more,
                  size: 16,
                  color: TradingStyle.muted,
                ),
              ),
            ],
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: !_open
              ? const SizedBox(width: double.infinity)
              : SizedBox(
                  height: widget.plotHeight,
                  width: double.infinity,
                  child: window.isEmpty
                      ? _empty()
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final plotted = TradingSeries.plot(window);
                            return GestureDetector(
                              onTapDown: (d) => _pick(
                                d.localPosition.dx,
                                constraints.maxWidth,
                                plotted,
                              ),
                              onHorizontalDragUpdate: (d) => _pick(
                                d.localPosition.dx,
                                constraints.maxWidth,
                                plotted,
                              ),
                              onTapUp: (_) => setState(() => _pressed = null),
                              onTapCancel: () =>
                                  setState(() => _pressed = null),
                              onHorizontalDragEnd: (_) =>
                                  setState(() => _pressed = null),
                              child: CustomPaint(
                                painter: _CandlePainter(candles: plotted),
                              ),
                            );
                          },
                        ),
                ),
        ),
      ],
    );
  }

  Widget _quoteText(
    List<Candlestick> window,
    double shown,
    TradingMove move,
    Color moveColor,
    Candlestick? readout,
  ) {
    if (widget.loading || window.isEmpty) {
      return Text(
        widget.loading ? 'Loading' : 'No history',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TradingStyle.caption(),
      );
    }
    final change = readout == null ? move.label : _stamp(readout.time);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: TradingSeries.price(shown),
            style: TradingStyle.figure(size: 13),
          ),
          const TextSpan(text: '  '),
          TextSpan(
            text: change,
            style: TradingStyle.caption(
              color: readout == null ? moveColor : TradingStyle.muted,
            ),
          ),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  void _pick(double dx, double width, List<Candlestick> plotted) {
    if (plotted.isEmpty || width <= 0) return;
    final index = (dx / width * plotted.length).floor().clamp(
      0,
      plotted.length - 1,
    );
    final window = _window;
    final ratio = plotted.length == 1 ? 0.0 : index / (plotted.length - 1);
    final source = (ratio * (window.length - 1)).round().clamp(
      0,
      window.length - 1,
    );
    setState(() => _pressed = source);
  }

  Widget _chip(TradingSpan span) {
    final selected = span == _span;
    return GestureDetector(
      onTap: () => setState(() {
        _span = span;
        _pressed = null;
      }),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Text(
          span.label,
          style: TradingStyle.caption(
            size: 10,
            color: selected ? TradingStyle.accent : TradingStyle.muted,
          ),
        ),
      ),
    );
  }

  Widget _empty() {
    return ColoredBox(
      color: TradingStyle.panel,
      child: Center(
        child: Text(
          widget.loading ? 'Loading history' : 'No ${widget.symbol} history',
          style: TradingStyle.caption(),
        ),
      ),
    );
  }

  static String _stamp(int unix) {
    final date = DateTime.fromMillisecondsSinceEpoch(unix * 1000, isUtc: true);
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '${date.year}-$m-$d';
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter({required this.candles});

  final List<Candlestick> candles;

  @override
  void paint(Canvas canvas, Size size) {
    if (candles.isEmpty || size.isEmpty) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = TradingStyle.panel);

    const labelW = 52.0;
    final plot = Rect.fromLTWH(0, 6, size.width - labelW, size.height - 12);
    var lo = candles.first.low;
    var hi = candles.first.high;
    for (final c in candles) {
      if (c.low < lo) lo = c.low;
      if (c.high > hi) hi = c.high;
    }
    if ((hi - lo).abs() < 1e-12) {
      hi = lo + 1;
    }
    final pad = (hi - lo) * 0.08;
    hi += pad;
    lo -= pad;

    double yOf(double price) =>
        plot.bottom - (price - lo) / (hi - lo) * plot.height;

    final grid = Paint()
      ..color = TradingStyle.hairline
      ..strokeWidth = 1;
    for (var i = 0; i < 3; i++) {
      final y = plot.top + plot.height * i / 2;
      canvas.drawLine(Offset(0, y), Offset(plot.right, y), grid);
    }

    final slot = plot.width / candles.length;
    final bodyW = (slot * 0.62).clamp(1.0, 8.0);
    for (var i = 0; i < candles.length; i++) {
      final c = candles[i];
      final up = c.close >= c.open;
      final color = up ? TradingStyle.gain : TradingStyle.loss;
      final x = plot.left + slot * i + slot / 2;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1;
      canvas.drawLine(Offset(x, yOf(c.high)), Offset(x, yOf(c.low)), paint);
      final top = yOf(up ? c.close : c.open);
      final bottom = yOf(up ? c.open : c.close);
      final body = Rect.fromLTRB(
        x - bodyW / 2,
        top,
        x + bodyW / 2,
        (bottom - top).abs() < 1 ? top + 1 : bottom,
      );
      canvas.drawRect(body, Paint()..color = color);
    }

    _label(canvas, TradingSeries.price(hi - pad), plot.top, size.width);
    _label(canvas, TradingSeries.price(lo + pad), plot.bottom - 10, size.width);
  }

  void _label(Canvas canvas, String text, double y, double width) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TradingStyle.caption(size: 9)),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: 50);
    painter.paint(canvas, Offset(width - 50, y));
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) => old.candles != candles;
}
