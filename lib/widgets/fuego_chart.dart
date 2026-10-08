import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../models/candlestick.dart';
import '../services/hearth_spot_history_service.dart';
import '../services/price_history_service.dart';

const _priceAxisWidth = 66.0;
const _timeAxisHeight = 20.0;

enum XfgHistoryQuote { usd, heat }

class _HistoryPoint {
  final int time;
  final double price;
  final bool observed;

  const _HistoryPoint(this.time, this.price, {this.observed = false});
}

class XfgHistoryPanel extends StatefulWidget {
  final String contextNote;
  final Color lineColor;
  final Color bgColor;
  final XfgHistoryQuote quote;
  final List<HearthSpotObservation> observedSpots;

  const XfgHistoryPanel({
    super.key,
    required this.contextNote,
    this.lineColor = const Color(0xFFC5A059),
    this.bgColor = const Color(0xFF0D0B08),
    this.quote = XfgHistoryQuote.usd,
    this.observedSpots = const [],
  });

  @override
  State<XfgHistoryPanel> createState() => _XfgHistoryPanelState();
}

class _XfgHistoryPanelState extends State<XfgHistoryPanel> {
  late Future<List<Candlestick>> _history;

  @override
  void initState() {
    super.initState();
    _history = widget.quote == XfgHistoryQuote.usd
        ? PriceHistoryService().loadAll()
        : Future.value(const []);
  }

  @override
  void didUpdateWidget(covariant XfgHistoryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quote != widget.quote &&
        widget.quote == XfgHistoryQuote.usd) {
      _history = PriceHistoryService().loadAll();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.quote == XfgHistoryQuote.heat) {
      return FuegoChart(
        candles: const [],
        contextNote: widget.contextNote,
        lineColor: widget.lineColor,
        bgColor: widget.bgColor,
        quote: widget.quote,
        observedSpots: widget.observedSpots,
      );
    }
    return FutureBuilder<List<Candlestick>>(
      future: _history,
      builder: (context, snapshot) {
        final candles = snapshot.data;
        if (candles != null && candles.isNotEmpty) {
          return FuegoChart(
            candles: candles,
            contextNote: widget.contextNote,
            lineColor: widget.lineColor,
            bgColor: widget.bgColor,
            quote: widget.quote,
            observedSpots: widget.observedSpots,
          );
        }
        return ColoredBox(
          color: widget.bgColor,
          child: Center(
            child: snapshot.hasError || (candles != null && candles.isEmpty)
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('XFG history unavailable'),
                      TextButton(
                        onPressed: () => setState(
                          () => _history = PriceHistoryService().loadAll(),
                        ),
                        child: const Text('Retry'),
                      ),
                    ],
                  )
                : const CircularProgressIndicator(),
          ),
        );
      },
    );
  }
}

class FuegoChart extends StatefulWidget {
  final List<Candlestick> candles;
  final String contextNote;
  final Color lineColor;
  final Color bgColor;
  final XfgHistoryQuote quote;
  final List<HearthSpotObservation> observedSpots;

  const FuegoChart({
    super.key,
    required this.candles,
    required this.contextNote,
    this.lineColor = const Color(0xFFC5A059),
    this.bgColor = const Color(0xFF0D0B08),
    this.quote = XfgHistoryQuote.usd,
    this.observedSpots = const [],
  });

  @override
  State<FuegoChart> createState() => _FuegoChartState();
}

class _FuegoChartState extends State<FuegoChart> {
  late List<_HistoryPoint> _archive;
  late List<_HistoryPoint> _observed;
  double _windowStart = 0;
  double _windowEnd = 0;
  double _gestureStart = 0;
  double _gestureEnd = 0;
  double _gestureFocalX = 0;
  _HistoryPoint? _focusedPoint;
  String _selectedRange = 'ALL';

  bool get _hasData => _archive.isNotEmpty || _observed.isNotEmpty;

  double get _firstTime {
    if (_archive.isNotEmpty) return _archive.first.time.toDouble();
    if (_observed.length == 1) {
      return (_observed.first.time - 7 * Duration.secondsPerDay).toDouble();
    }
    return _observed.first.time.toDouble();
  }

  double get _lastTime {
    if (_archive.isEmpty && _observed.length == 1) {
      return (_observed.last.time + Duration.secondsPerDay).toDouble();
    }
    return math
        .max(
          _archive.isEmpty ? 0 : _archive.last.time,
          _observed.isEmpty ? 0 : _observed.last.time,
        )
        .toDouble();
  }

  void _prepareSeries() {
    _archive = widget.quote == XfgHistoryQuote.usd
        ? [
            for (final candle in widget.candles)
              _HistoryPoint(candle.time, candle.close),
          ]
        : [];
    _observed = widget.quote == XfgHistoryQuote.heat
        ? ([
            for (final spot in widget.observedSpots)
              _HistoryPoint(spot.time, spot.heatPerXfg, observed: true),
          ]..sort((a, b) => a.time.compareTo(b.time)))
        : [];
  }

  @override
  void initState() {
    super.initState();
    _prepareSeries();
    if (_hasData) {
      _windowStart = _firstTime;
      _windowEnd = _lastTime;
    }
  }

  @override
  void didUpdateWidget(covariant FuegoChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.candles != widget.candles ||
        oldWidget.observedSpots != widget.observedSpots ||
        oldWidget.quote != widget.quote) {
      _prepareSeries();
      if (!_hasData) return;
      if (oldWidget.candles != widget.candles ||
          oldWidget.quote != widget.quote ||
          _selectedRange == 'ALL') {
        _windowStart = _firstTime;
        _windowEnd = _lastTime;
        _selectedRange = 'ALL';
      } else if (_selectedRange != 'CUSTOM') {
        final span = _windowEnd - _windowStart;
        _windowEnd = _lastTime;
        _windowStart = math.max(_firstTime, _windowEnd - span);
      }
      _focusedPoint = null;
    }
  }

  void _chooseRange(String label, int? days) {
    if (!_hasData) return;
    if (days == null) {
      setState(() {
        _windowStart = _firstTime;
        _windowEnd = _lastTime;
        _focusedPoint = null;
        _selectedRange = label;
      });
      return;
    }
    setState(() {
      _windowEnd = _lastTime;
      _windowStart = math.max(
        _firstTime,
        _windowEnd - days * Duration.secondsPerDay,
      );
      _focusedPoint = null;
      _selectedRange = label;
    });
  }

  void _setWindow(double requestedStart, double requestedSpan) {
    final totalSpan = _lastTime - _firstTime;
    if (totalSpan <= 0) return;
    final span = requestedSpan
        .clamp(
          math.min(7 * Duration.secondsPerDay.toDouble(), totalSpan),
          totalSpan,
        )
        .toDouble();
    final start = requestedStart.clamp(_firstTime, _lastTime - span).toDouble();
    if ((_windowStart - start).abs() < 0.001 &&
        (_windowEnd - start - span).abs() < 0.001) {
      return;
    }
    setState(() {
      _windowStart = start;
      _windowEnd = start + span;
      _focusedPoint = null;
      _selectedRange = 'CUSTOM';
    });
  }

  void _focusAt(double x, double plotWidth) {
    if (!_hasData) return;
    final fraction = (x / plotWidth).clamp(0.0, 1.0);
    final targetTime = _windowStart + fraction * (_windowEnd - _windowStart);
    _HistoryPoint? nearest;
    var distance = double.infinity;
    for (final point in [..._archive, ..._observed]) {
      if (point.time < _windowStart || point.time > _windowEnd) continue;
      final nextDistance = (point.time - targetTime).abs();
      if (nextDistance < distance) {
        nearest = point;
        distance = nextDistance;
      }
    }
    if (nearest != _focusedPoint) setState(() => _focusedPoint = nearest);
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasData) {
      return ColoredBox(
        color: widget.bgColor,
        child: Center(
          child: Text(
            widget.quote == XfgHistoryQuote.heat
                ? 'No Hearth pool observations yet'
                : 'No XFG price history',
            style: const TextStyle(color: Color(0xFFAAA096)),
          ),
        ),
      );
    }
    final focused =
        _focusedPoint ??
        (_observed.isNotEmpty ? _observed.last : _archive.last);
    final isHeat = widget.quote == XfgHistoryQuote.heat;

    return ColoredBox(
      color: widget.bgColor,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 5, 10, 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        isHeat
                            ? 'XFG/HΞΔŦ · pool spot'
                            : 'XFG/USD · historical',
                        style: TextStyle(
                          color: widget.lineColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Flexible(
                      child: Text(
                        '${_date(focused.time)}  ${_price(focused.price, widget.quote)}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: focused.observed
                              ? const Color(0xFF8BBAC8)
                              : widget.lineColor,
                          fontSize: 10,
                        ),
                      ),
                    ),
                  ],
                ),
                Text(
                  isHeat
                      ? '${_date(_windowStart.round())} — ${_date(_windowEnd.round())} · ${_observed.length} local daily samples'
                      : '${_date(_windowStart.round())} — ${_date(_windowEnd.round())} · archive ends ${_date(_archive.last.time)}',
                  style: const TextStyle(color: Color(0xFFAAA096), fontSize: 9),
                ),
                Text(
                  isHeat
                      ? 'Observed pool spot only · missing days left blank'
                      : '${widget.contextNote} · not live',
                  style: const TextStyle(color: Color(0xFFAAA096), fontSize: 9),
                ),
                if (isHeat)
                  Text(
                    widget.contextNote,
                    style: const TextStyle(
                      color: Color(0xFFAAA096),
                      fontSize: 9,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final plotWidth = math.max(
                  1.0,
                  constraints.maxWidth - _priceAxisWidth,
                );
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) =>
                      _focusAt(details.localPosition.dx, plotWidth),
                  onScaleStart: (details) {
                    _gestureStart = _windowStart;
                    _gestureEnd = _windowEnd;
                    _gestureFocalX = details.localFocalPoint.dx;
                  },
                  onScaleUpdate: (details) {
                    final gestureSpan = _gestureEnd - _gestureStart;
                    final anchor =
                        _gestureStart +
                        (_gestureFocalX / plotWidth).clamp(0.0, 1.0) *
                            gestureSpan;
                    final span = gestureSpan / math.max(details.scale, 0.01);
                    final fraction = (details.localFocalPoint.dx / plotWidth)
                        .clamp(0.0, 1.0);
                    _setWindow(anchor - fraction * span, span);
                  },
                  child: MouseRegion(
                    onHover: (event) =>
                        _focusAt(event.localPosition.dx, plotWidth),
                    child: Listener(
                      onPointerSignal: (event) {
                        if (event is! PointerScrollEvent) return;
                        final fraction = (event.localPosition.dx / plotWidth)
                            .clamp(0.0, 1.0);
                        final span = _windowEnd - _windowStart;
                        final anchor = _windowStart + fraction * span;
                        final newSpan =
                            span * math.exp(event.scrollDelta.dy * 0.002);
                        _setWindow(anchor - fraction * newSpan, newSpan);
                      },
                      child: RepaintBoundary(
                        child: CustomPaint(
                          key: const Key('xfg-history-plot'),
                          painter: _HistoryLinePainter(
                            archive: _archive,
                            observed: _observed,
                            windowStart: _windowStart,
                            windowEnd: _windowEnd,
                            focusedPoint: _focusedPoint,
                            lineColor: widget.lineColor,
                            quote: widget.quote,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          SizedBox(
            height: 28,
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final (label, days) in const [
                  ('1M', 30),
                  ('3M', 90),
                  ('1Y', 365),
                  ('5Y', 1825),
                  ('ALL', null),
                ])
                  TextButton(
                    onPressed: () => _chooseRange(label, days),
                    style: TextButton.styleFrom(
                      foregroundColor: _selectedRange == label
                          ? widget.lineColor
                          : const Color(0xFFAAA096),
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      minimumSize: const Size(42, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(label, style: const TextStyle(fontSize: 10)),
                  ),
                const Padding(
                  padding: EdgeInsets.only(left: 8, right: 6),
                  child: Center(
                    child: Text(
                      'Drag / pinch / scroll to navigate',
                      style: TextStyle(color: Color(0xFFAAA096), fontSize: 9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryLinePainter extends CustomPainter {
  final List<_HistoryPoint> archive;
  final List<_HistoryPoint> observed;
  final double windowStart;
  final double windowEnd;
  final _HistoryPoint? focusedPoint;
  final Color lineColor;
  final XfgHistoryQuote quote;

  const _HistoryLinePainter({
    required this.archive,
    required this.observed,
    required this.windowStart,
    required this.windowEnd,
    required this.focusedPoint,
    required this.lineColor,
    required this.quote,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if ((archive.isEmpty && observed.isEmpty) || size.isEmpty) return;
    final plotWidth = math.max(1.0, size.width - _priceAxisWidth);
    final plotHeight = math.max(1.0, size.height - _timeAxisHeight);
    final visibleArchive = archive
        .where((point) => point.time >= windowStart && point.time <= windowEnd)
        .toList();
    final visibleObserved = observed
        .where((point) => point.time >= windowStart && point.time <= windowEnd)
        .toList();
    final visible = [...visibleArchive, ...visibleObserved];
    final timeSpan = math.max(windowEnd - windowStart, 1.0);
    double xFor(_HistoryPoint point) =>
        (point.time - windowStart) / timeSpan * plotWidth;
    final gridPaint = Paint()
      ..color = lineColor.withValues(alpha: 0.14)
      ..strokeWidth = 1;
    for (var tick = 0; tick <= 4; tick++) {
      final y = plotHeight * tick / 4;
      canvas.drawLine(Offset(0, y), Offset(plotWidth, y), gridPaint);
    }

    if (visible.isEmpty) {
      _drawText(
        canvas,
        'No observations in this period',
        Offset(8, plotHeight / 2),
        const Color(0xFFAAA096),
      );
    } else {
      final lowest = visible.map((point) => point.price).reduce(math.min);
      final highest = visible.map((point) => point.price).reduce(math.max);
      final padding = math.max((highest - lowest) * 0.08, highest * 0.02);
      final low = math.max(0.0, lowest - padding);
      final high = highest + padding;
      final priceSpan = math.max(high - low, 1e-12);
      double yFor(_HistoryPoint point) =>
          plotHeight - (point.price - low) / priceSpan * plotHeight;

      for (var tick = 0; tick <= 4; tick++) {
        final y = plotHeight * tick / 4;
        _drawText(
          canvas,
          _axisPrice(high - priceSpan * tick / 4, quote),
          Offset(plotWidth + 4, (y - 6).clamp(0.0, plotHeight - 10)),
          const Color(0xFFAAA096),
        );
      }

      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, plotWidth, plotHeight));
      _drawSeries(canvas, visibleArchive, xFor, yFor, lineColor);
      _drawSeries(
        canvas,
        visibleObserved,
        xFor,
        yFor,
        const Color(0xFF8BBAC8),
        splitMissingDays: true,
      );
      if (focusedPoint != null &&
          focusedPoint!.time >= windowStart &&
          focusedPoint!.time <= windowEnd) {
        final x = xFor(focusedPoint!);
        final y = yFor(focusedPoint!);
        final color = focusedPoint!.observed
            ? const Color(0xFF8BBAC8)
            : lineColor;
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, plotHeight),
          Paint()
            ..color = color.withValues(alpha: 0.55)
            ..strokeWidth = 1,
        );
        canvas.drawCircle(Offset(x, y), 3.5, Paint()..color = color);
      }
      canvas.restore();
    }

    final longRange = timeSpan > 365 * Duration.secondsPerDay;
    for (final fraction in const [0.0, 0.5, 1.0]) {
      final time = (windowStart + fraction * timeSpan).round();
      final label = _axisDate(time, longRange);
      final painter = _textPainter(label, const Color(0xFFAAA096));
      final x = (fraction * plotWidth - painter.width / 2).clamp(
        0.0,
        math.max(0.0, plotWidth - painter.width),
      );
      painter.paint(canvas, Offset(x.toDouble(), plotHeight + 4));
    }
  }

  void _drawSeries(
    Canvas canvas,
    List<_HistoryPoint> points,
    double Function(_HistoryPoint) xFor,
    double Function(_HistoryPoint) yFor,
    Color color, {
    bool splitMissingDays = false,
  }) {
    if (points.isEmpty) return;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    for (var index = 1; index < points.length; index++) {
      final previous = points[index - 1];
      final current = points[index];
      if (splitMissingDays &&
          current.time ~/ Duration.secondsPerDay -
                  previous.time ~/ Duration.secondsPerDay >
              1) {
        continue;
      }
      canvas.drawLine(
        Offset(xFor(previous), yFor(previous)),
        Offset(xFor(current), yFor(current)),
        paint,
      );
    }
    if (points.length == 1 || splitMissingDays) {
      for (final point in points) {
        canvas.drawCircle(
          Offset(xFor(point), yFor(point)),
          2.5,
          Paint()..color = color,
        );
      }
    }
  }

  void _drawText(Canvas canvas, String text, Offset offset, Color color) {
    _textPainter(text, color).paint(canvas, offset);
  }

  TextPainter _textPainter(String text, Color color) => TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: 9, fontFamily: 'IBMPlexMono'),
    ),
    textDirection: TextDirection.ltr,
  )..layout();

  @override
  bool shouldRepaint(covariant _HistoryLinePainter oldDelegate) =>
      oldDelegate.archive != archive ||
      oldDelegate.observed != observed ||
      oldDelegate.windowStart != windowStart ||
      oldDelegate.windowEnd != windowEnd ||
      oldDelegate.focusedPoint != focusedPoint ||
      oldDelegate.lineColor != lineColor ||
      oldDelegate.quote != quote;
}

String _date(int unixSeconds) {
  final date = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
    isUtc: true,
  );
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String _price(double value, XfgHistoryQuote quote) =>
    quote == XfgHistoryQuote.usd
    ? '\$${value.toStringAsFixed(8)}'
    : value.toStringAsFixed(8);

String _axisPrice(double value, XfgHistoryQuote quote) {
  final prefix = quote == XfgHistoryQuote.usd ? '\$' : '';
  if (value >= 1) return '$prefix${value.toStringAsFixed(2)}';
  if (value >= 0.01) return '$prefix${value.toStringAsFixed(4)}';
  return '$prefix${value.toStringAsFixed(6)}';
}

String _axisDate(int unixSeconds, bool longRange) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final date = DateTime.fromMillisecondsSinceEpoch(
    unixSeconds * 1000,
    isUtc: true,
  );
  return longRange
      ? '${months[date.month - 1]} ${date.year}'
      : '${months[date.month - 1]} ${date.day}';
}
