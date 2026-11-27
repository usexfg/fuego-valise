import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/candlestick.dart';
import '../../services/price_history_service.dart';
import 'trading_series.dart';
import 'trading_style.dart';

/// Right-hand gutter for the price axis. Painting and touch mapping share it,
/// so the crosshair always sits under the finger.
const double _priceGutter = 52;

/// Quote row, timeframe chips, and a collapsible line chart.
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
    this.color,
  });

  final List<Candlestick> candles;
  final String symbol;
  final String quote;
  final bool history;
  final bool loading;
  final double plotHeight;
  final bool initiallyOpen;

  /// Brand color of the selected pair. The line and its faded gradient follow
  /// it; the quote row keeps terminal green/red for direction.
  final Color? color;

  @override
  State<TradingChart> createState() => _TradingChartState();
}

class _TradingChartState extends State<TradingChart> {
  /// Pinch ceiling. 12× is enough to read a single day inside ALL history.
  static const double maxZoom = 12;
  static const Duration _holdDelay = Duration(milliseconds: 220);
  static const double _scrubSlop = 24;

  TradingSpan _span = TradingSpan.year;
  late bool _open = widget.initiallyOpen;
  int? _pressed;
  bool _held = false;
  int _pointers = 0;
  double _zoom = 1;
  double _center = 0.5;

  Timer? _holdTimer;
  double _plotWidth = 1;
  double _travel = 0;
  Offset _lastFocal = Offset.zero;
  double _startZoom = 1;
  double _startCenter = 0.5;
  List<Candlestick> _plotted = const [];
  List<Candlestick> _visible = const [];

  Color get _brand {
    final brand = widget.color ?? TradingStyle.accent;
    // Navy brands (CRO, BASE) would vanish on the terminal panel; lift only
    // the very dark ones toward white, keeping their hue.
    return brand.computeLuminance() < 0.06
        ? Color.lerp(brand, Colors.white, 0.35)!
        : brand;
  }

  List<Candlestick> get _window {
    if (widget.loading) return const [];
    // No pair history: start at the launch rate, not "no history".
    final all = widget.candles.isEmpty
        ? PriceHistoryService().launchSeries()
        : widget.candles;
    return TradingSeries.window(all, _span);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final window = _window;
    final move = TradingSeries.moveOf(window);
    final readout = _pressed != null && _pressed! < _visible.length
        ? _visible[_pressed!]
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
                            _plotWidth = constraints.maxWidth;
                            _visible = TradingSeries.slice(
                              window,
                              _zoom,
                              _center,
                            );
                            _plotted = TradingSeries.plot(
                              _visible,
                              maxPoints: (constraints.maxWidth / 2)
                                  .ceil()
                                  .clamp(120, 480),
                            );
                            final crosshair =
                                _pressed == null || _plotted.length < 2
                                ? null
                                : (_pressed! /
                                          (_visible.length - 1) *
                                          (_plotted.length - 1))
                                      .round()
                                      .clamp(0, _plotted.length - 1);
                            return MouseRegion(
                              onHover: (e) => _pick(e.localPosition.dx),
                              onExit: (_) => setState(() => _pressed = null),
                              child: Listener(
                                onPointerDown: _onPointerDown,
                                onPointerMove: _onPointerMove,
                                onPointerUp: (_) => _dropPointer(),
                                onPointerCancel: (_) => _dropPointer(),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onScaleStart: _onScaleStart,
                                  onScaleUpdate: _onScaleUpdate,
                                  onScaleEnd: _onScaleEnd,
                                  // The chart eats vertical drags so the page
                                  // scrolls from the space below it, not the
                                  // plot.
                                  onVerticalDragUpdate: (_) {},
                                  onDoubleTap: _resetZoom,
                                  child: Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      CustomPaint(
                                        painter: _LinePainter(
                                          points: _plotted,
                                          color: _brand,
                                          crosshair: crosshair,
                                          held: _held,
                                          startLabel: _stamp(
                                            _visible.first.time,
                                          ),
                                          endLabel: _stamp(_visible.last.time),
                                        ),
                                      ),
                                      if (_held)
                                        const Positioned.fill(
                                          child: IgnorePointer(
                                            child: ColoredBox(
                                              color: Color(0x29000000),
                                            ),
                                          ),
                                        ),
                                      // A hold reads out the point. A plain
                                      // scrub keeps the light crosshair and
                                      // the quote row only.
                                      if (_held && readout != null)
                                        Positioned(
                                          left: 8,
                                          top: 4,
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                TradingSeries.price(
                                                  readout.close,
                                                ),
                                                style: TradingStyle.figure(
                                                  size: 14,
                                                ),
                                              ),
                                              const SizedBox(height: 1),
                                              Text(
                                                '${_stamp(readout.time)}  ·  '
                                                'Vol ${TradingSeries.volume(readout.volume)}',
                                                style: TradingStyle.caption(
                                                  size: 9,
                                                  color: TradingStyle.text,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
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

  void _onPointerDown(PointerDownEvent d) {
    _pointers++;
    if (_pointers > 1) {
      // A second finger means pinch, not hold.
      _holdTimer?.cancel();
      if (_held || _pressed != null) {
        setState(() {
          _held = false;
          _pressed = null;
        });
      }
      return;
    }
    _travel = 0;
    _lastFocal = d.localPosition;
    _pick(d.localPosition.dx);
    _holdTimer?.cancel();
    _holdTimer = Timer(_holdDelay, () {
      if (mounted) setState(() => _held = true);
    });
  }

  void _onPointerMove(PointerMoveEvent d) {
    if (_pointers != 1) return;
    _travel += (d.localPosition - _lastFocal).distance;
    _lastFocal = d.localPosition;
    if (_travel > _scrubSlop) {
      _holdTimer?.cancel();
      if (_held) setState(() => _held = false);
    }
    // Follow the finger even when a vertical drag recognizer owns the arena.
    _pick(d.localPosition.dx);
  }

  void _dropPointer() {
    if (_pointers > 0) _pointers--;
    if (_pointers == 0) _release();
  }

  void _release() {
    _holdTimer?.cancel();
    if (_held || _pressed != null) {
      setState(() {
        _held = false;
        _pressed = null;
      });
    }
  }

  void _onScaleStart(ScaleStartDetails d) {
    _startZoom = _zoom;
    _startCenter = _center;
    // A two-finger start is a pinch; the crosshair belongs to a single finger.
    if (d.pointerCount < 2) _pick(d.localFocalPoint.dx);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      _holdTimer?.cancel();
      if (_held) setState(() => _held = false);
      _zoomTo(_startZoom * d.scale, d.localFocalPoint.dx);
      return;
    }
    _pick(d.localFocalPoint.dx);
  }

  void _onScaleEnd(ScaleEndDetails d) {
    if (_pointers == 0) _release();
  }

  void _zoomTo(double zoom, double focalDx) {
    final next = zoom.clamp(1.0, maxZoom);
    final plotW = _plotWidth - _priceGutter;
    final focal = plotW <= 0 ? 0.5 : (focalDx / plotW).clamp(0.0, 1.0);
    setState(() {
      _zoom = next;
      _center = TradingSeries.centerForZoom(
        _startZoom,
        _startCenter,
        next,
        focal,
      );
    });
  }

  void _resetZoom() {
    _holdTimer?.cancel();
    setState(() {
      _zoom = 1;
      _center = 0.5;
      _held = false;
      _pressed = null;
    });
  }

  void _pick(double dx) {
    if (_plotted.isEmpty || _visible.isEmpty) return;
    final plotW = _plotWidth - _priceGutter;
    if (plotW <= 0) return;
    final x = dx.clamp(0.0, plotW);
    final index = (x / plotW * (_plotted.length - 1)).round().clamp(
      0,
      _plotted.length - 1,
    );
    final ratio = _plotted.length == 1 ? 0.0 : index / (_plotted.length - 1);
    final source = (ratio * (_visible.length - 1)).round().clamp(
      0,
      _visible.length - 1,
    );
    if (_pressed != source) setState(() => _pressed = source);
  }

  Widget _chip(TradingSpan span) {
    final selected = span == _span;
    return GestureDetector(
      onTap: () => setState(() {
        _span = span;
        _pressed = null;
        _zoom = 1;
        _center = 0.5;
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

/// Close-price line over a faded gradient of the pair's brand color.
class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.points,
    required this.color,
    required this.crosshair,
    required this.held,
    required this.startLabel,
    required this.endLabel,
  });

  final List<Candlestick> points;
  final Color color;
  final int? crosshair;
  final bool held;
  final String startLabel;
  final String endLabel;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.isEmpty) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = TradingStyle.panel);

    final plot = Rect.fromLTWH(
      0,
      8,
      size.width - _priceGutter,
      size.height - 24,
    );
    if (plot.width <= 0 || plot.height <= 0) return;

    canvas.drawRect(
      plot,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: held ? 0.12 : 0.07),
            color.withValues(alpha: 0),
          ],
        ).createShader(plot),
    );

    var lo = points.first.low;
    var hi = points.first.high;
    for (final c in points) {
      if (c.low < lo) lo = c.low;
      if (c.high > hi) hi = c.high;
    }
    if ((hi - lo).abs() < 1e-12) hi = lo + 1;
    final pad = (hi - lo) * 0.08;
    hi += pad;
    lo -= pad;

    double yOf(double price) =>
        plot.bottom - (price - lo) / (hi - lo) * plot.height;
    double xOf(int i) => points.length == 1
        ? plot.center.dx
        : plot.left + plot.width * i / (points.length - 1);

    final grid = Paint()
      ..color = TradingStyle.hairline.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (var i = 0; i <= 2; i++) {
      final y = plot.top + plot.height * i / 2;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
    }

    final line = Path()..moveTo(xOf(0), yOf(points.first.close));
    for (var i = 1; i < points.length; i++) {
      line.lineTo(xOf(i), yOf(points[i].close));
    }
    final area = Path.from(line)
      ..lineTo(xOf(points.length - 1), plot.bottom)
      ..lineTo(xOf(0), plot.bottom)
      ..close();
    canvas
      ..drawPath(
        area,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              color.withValues(alpha: held ? 0.30 : 0.22),
              color.withValues(alpha: 0),
            ],
          ).createShader(plot),
      )
      ..drawPath(
        line,
        Paint()
          ..color = color
          ..strokeWidth = 1.6
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
      );

    final lastY = yOf(points.last.close);
    canvas.drawCircle(
      Offset(xOf(points.length - 1), lastY),
      2.5,
      Paint()..color = color,
    );

    final at = crosshair;
    if (at != null && at >= 0 && at < points.length) {
      final x = xOf(at);
      final y = yOf(points[at].close);
      canvas
        ..drawLine(
          Offset(x, plot.top),
          Offset(x, plot.bottom),
          Paint()
            ..color = Colors.white.withValues(alpha: held ? 0.55 : 0.22)
            ..strokeWidth = 1,
        )
        ..drawCircle(Offset(x, y), 3.5, Paint()..color = color)
        ..drawCircle(
          Offset(x, y),
          3.5,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.7)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
      _tag(canvas, TradingSeries.price(points[at].close), y, plot, held);
    }

    _label(canvas, TradingSeries.price(hi - pad), plot.top, size.width);
    _label(canvas, TradingSeries.price(lo + pad), plot.bottom - 10, size.width);
    _xLabel(canvas, startLabel, plot.left, plot.bottom + 4, false);
    _xLabel(canvas, endLabel, plot.right, plot.bottom + 4, true);
  }

  void _label(Canvas canvas, String text, double y, double width) {
    TextPainter(
        text: TextSpan(text: text, style: TradingStyle.caption(size: 9)),
        textDirection: TextDirection.ltr,
      )
      ..layout(maxWidth: 50)
      ..paint(canvas, Offset(width - 50, y));
  }

  void _xLabel(
    Canvas canvas,
    String text,
    double x,
    double y,
    bool alignRight,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: TradingStyle.caption(size: 8.5)),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, Offset(alignRight ? x - painter.width : x, y));
  }

  void _tag(Canvas canvas, String text, double y, Rect plot, bool held) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TradingStyle.caption(
          size: 9,
          color: held ? TradingStyle.text : TradingStyle.muted,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    const w = 50.0;
    final top = (y - painter.height / 2).clamp(4.0, plot.bottom - 12);
    final rect = Rect.fromLTWH(plot.right, top, w, painter.height + 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      Paint()..color = TradingStyle.panel.withValues(alpha: 0.92),
    );
    painter.paint(canvas, Offset(rect.left + 3, rect.top + 1));
  }

  @override
  bool shouldRepaint(covariant _LinePainter old) =>
      old.points != points ||
      old.color != color ||
      old.crosshair != crosshair ||
      old.held != held ||
      old.startLabel != startLabel ||
      old.endLabel != endLabel;
}
