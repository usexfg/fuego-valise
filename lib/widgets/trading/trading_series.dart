import '../../models/candlestick.dart';
import '../../models/portfolio.dart';

/// Window the quote and the chart share. The label is part of the change:
/// a 1Y move must not be readable as today's P&L.
enum TradingSpan {
  month('1M', 30 * 86400),
  quarter('3M', 90 * 86400),
  year('1Y', 365 * 86400),
  all('ALL', null);

  const TradingSpan(this.label, this.seconds);

  final String label;

  /// Null means the whole series.
  final int? seconds;
}

/// Open-to-close move of one window. Flat when the series cannot support a
/// percent, so callers never invent one.
class TradingMove {
  const TradingMove({
    required this.open,
    required this.close,
    required this.delta,
    required this.percent,
    required this.known,
  });

  const TradingMove.unknown()
    : open = 0,
      close = 0,
      delta = 0,
      percent = 0,
      known = false;

  final double open;
  final double close;
  final double delta;

  /// Percent change. Meaningful only when [known] is true.
  final double percent;
  final bool known;

  bool get up => known && delta > 0;
  bool get down => known && delta < 0;
  bool get flat => !known || delta == 0;

  /// Arrow + signed percent. Color is applied by the caller, never implied.
  String get label {
    if (!known) return '—';
    final arrow = up
        ? '▲'
        : down
        ? '▼'
        : '–';
    final sign = up ? '+' : '';
    return '$arrow $sign${percent.toStringAsFixed(1)}%';
  }
}

/// Slice, downsample, and quote a candle series without inventing points.
class TradingSeries {
  TradingSeries._();

  static const int maxPoints = 160;

  static List<Candlestick> window(List<Candlestick> all, TradingSpan span) {
    if (all.isEmpty) return const [];
    final seconds = span.seconds;
    if (seconds == null) return List<Candlestick>.from(all);
    final cutoff = all.last.time - seconds;
    return all.where((c) => c.time >= cutoff).toList(growable: false);
  }

  /// Bucket a long series so a phone-width chart stays readable. The first
  /// and last candles are kept, so the window's open and close survive.
  static List<Candlestick> plot(
    List<Candlestick> candles, {
    int maxPoints = maxPoints,
  }) {
    if (candles.length <= maxPoints || maxPoints < 2) return candles;
    final out = <Candlestick>[];
    final buckets = maxPoints - 1;
    for (var i = 0; i < buckets; i++) {
      final start = (i * candles.length / buckets).floor();
      final end = ((i + 1) * candles.length / buckets).floor();
      out.add(
        _bucket(candles.sublist(start, end.clamp(start + 1, candles.length))),
      );
    }
    out.add(candles.last);
    return out;
  }

  static Candlestick _bucket(List<Candlestick> slice) {
    var high = slice.first.high;
    var low = slice.first.low;
    var volume = 0.0;
    for (final c in slice) {
      if (c.high > high) high = c.high;
      if (c.low < low) low = c.low;
      volume += c.volume;
    }
    return Candlestick(
      time: slice.first.time,
      open: slice.first.open,
      high: high,
      low: low,
      close: slice.last.close,
      volume: volume,
    );
  }

  /// Contiguous visible slice for a zoom level. [center] is the fraction of the
  /// window sitting at the viewport center; zoom 1 always returns everything.
  /// The slice stays a real slice of the data, so a zoomed chart is never a
  /// stretched low-resolution render.
  static List<Candlestick> slice(
    List<Candlestick> window,
    double zoom,
    double center,
  ) {
    if (window.isEmpty || zoom <= 1.001) return window;
    // A one-candle window can't satisfy the 2-point floor: keep it.
    final visible = window.length <= 2
        ? window.length
        : (window.length / zoom).round().clamp(2, window.length);
    final maxStart = window.length - visible;
    final v = visible / window.length;
    final startFrac = (center - v / 2).clamp(0.0, 1.0 - v);
    final start = (startFrac * window.length).round().clamp(0, maxStart);
    return window.sublist(start, start + visible);
  }

  /// Viewport center for a pinch: keeps the data fraction under
  /// [focalFraction] of the viewport fixed while the zoom moves from
  /// [startZoom] to [targetZoom]. Clamped to the window.
  static double centerForZoom(
    double startZoom,
    double startCenter,
    double targetZoom,
    double focalFraction,
  ) {
    final v0 = 1 / startZoom;
    final v1 = 1 / targetZoom;
    final absolute = startCenter + (focalFraction - 0.5) * v0;
    return (absolute - (focalFraction - 0.5) * v1).clamp(v1 / 2, 1 - v1 / 2);
  }

  /// Open of the first candle to close of the last. Independent of downsampling.
  static TradingMove moveOf(List<Candlestick> candles) {
    if (candles.isEmpty) return const TradingMove.unknown();
    final open = candles.first.open;
    final close = candles.last.close;
    if (!open.isFinite || !close.isFinite || open == 0) {
      return TradingMove(
        open: open,
        close: close,
        delta: close - open,
        percent: 0,
        known: false,
      );
    }
    final delta = close - open;
    return TradingMove(
      open: open,
      close: close,
      delta: delta,
      percent: delta / open * 100,
      known: true,
    );
  }

  static String price(double value) {
    if (!value.isFinite) return '—';
    if (value.abs() >= 1000) return groupThousands(value.toStringAsFixed(2));
    if (value.abs() >= 1) return value.toStringAsFixed(2);
    if (value.abs() >= 0.01) return value.toStringAsFixed(4);
    return value.toStringAsFixed(6);
  }

  /// Compact volume for the crosshair readout. Zero volume is a dash, not 0.
  static String volume(double value) {
    if (!value.isFinite || value <= 0) return '—';
    if (value >= 1e9) return '${(value / 1e9).toStringAsFixed(2)}B';
    if (value >= 1e6) return '${(value / 1e6).toStringAsFixed(2)}M';
    if (value >= 1e3) return '${(value / 1e3).toStringAsFixed(1)}K';
    return value.toStringAsFixed(0);
  }
}
