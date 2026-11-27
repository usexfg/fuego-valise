import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/candlestick.dart';
import 'package:fuego/widgets/trading/trading_series.dart';

Candlestick _bar(int day, double open, double close) => Candlestick(
  time: day * 86400,
  open: open,
  high: open > close ? open : close,
  low: open < close ? open : close,
  close: close,
);

void main() {
  group('TradingSeries', () {
    test('a month keeps only bars inside the window of the last close', () {
      final all = [
        _bar(0, 1, 1),
        _bar(10, 1, 1.1),
        _bar(40, 1.1, 1.2),
        _bar(60, 1.2, 0.9),
      ];
      final month = TradingSeries.window(all, TradingSpan.month);
      expect(month.map((c) => c.time).toList(), [40 * 86400, 60 * 86400]);
    });

    test('the last bar is always inside its own window', () {
      final all = [_bar(0, 2, 3)];
      final month = TradingSeries.window(all, TradingSpan.month);
      expect(month, hasLength(1));
      expect(month.single.close, 3);
    });

    test('plot keeps the first open and the last close', () {
      final all = List.generate(400, (i) => _bar(i, i.toDouble(), i + 0.5));
      final plotted = TradingSeries.plot(all);
      expect(plotted.length, lessThanOrEqualTo(TradingSeries.maxPoints));
      expect(plotted.first.open, 0);
      expect(plotted.last.close, 399.5);
    });

    test('move is the window open to the window close, with an arrow', () {
      final move = TradingSeries.moveOf([
        _bar(1, 1.0, 1.1),
        _bar(2, 1.1, 1.25),
      ]);
      expect(move.known, isTrue);
      expect(move.up, isTrue);
      expect(move.percent, closeTo(25, 1e-9));
      expect(move.label, '▲ +25.0%');
    });

    test('a down move carries a down arrow, not just a color', () {
      final move = TradingSeries.moveOf([_bar(1, 2, 2), _bar(2, 2, 1)]);
      expect(move.down, isTrue);
      expect(move.label, startsWith('▼'));
    });

    test('a zero open is unknown, not an infinite percent', () {
      final move = TradingSeries.moveOf([_bar(1, 0, 1)]);
      expect(move.known, isFalse);
      expect(move.label, '—');
    });

    test('price keeps small historical prints', () {
      expect(TradingSeries.price(0.000709), '0.000709');
      expect(TradingSeries.price(0.632), '0.6320');
      expect(TradingSeries.price(double.nan), '—');
    });

    test('volume is compact, and zero reads as unknown', () {
      expect(TradingSeries.volume(0), '—');
      expect(TradingSeries.volume(double.nan), '—');
      expect(TradingSeries.volume(999), '999');
      expect(TradingSeries.volume(1500), '1.5K');
      expect(TradingSeries.volume(2.3e6), '2.30M');
      expect(TradingSeries.volume(1.2e9), '1.20B');
    });

    test('zoom 1 shows the whole window', () {
      final all = List.generate(40, (i) => _bar(i, 1, 1 + i * 0.01));
      expect(TradingSeries.slice(all, 1, 0.5), all);
    });

    test('a zoomed slice stays contiguous and inside the window', () {
      final all = List.generate(100, (i) => _bar(i, 1, 1 + i * 0.01));
      final zoomed = TradingSeries.slice(all, 4, 0.5);
      expect(zoomed.length, 25);
      // Centered: the viewport opens a quarter in, not at the first bar.
      expect(zoomed.first.time, 38 * 86400);
      expect(zoomed.last.time, 62 * 86400);
      for (var i = 1; i < zoomed.length; i++) {
        expect(zoomed[i].time - zoomed[i - 1].time, 86400);
      }
    });

    test('an edge-centered zoom clamps instead of running off the window', () {
      final all = List.generate(80, (i) => _bar(i, 1, 1 + i * 0.01));
      final start = TradingSeries.slice(all, 8, 0);
      final end = TradingSeries.slice(all, 8, 1);
      expect(start.first.time, all.first.time);
      expect(end.last.time, all.last.time);
      expect(start.length, 10);
      expect(end.length, 10);
      expect(end.first.time, 70 * 86400);
    });

    test('pinching keeps the data under the finger fixed', () {
      final center = TradingSeries.centerForZoom(1, 0.5, 4, 0.2);
      const v1 = 1 / 4;
      final under = center + (0.2 - 0.5) * v1;
      expect(under, closeTo(0.2, 1e-9));
      expect(center, closeTo(0.2 + 0.3 * v1, 1e-9));
    });

    test('zooming back out lands on the whole window', () {
      expect(TradingSeries.centerForZoom(4, 0.1, 1, 0.9), 0.5);
    });

    test('a pinch at the edge stays inside the window', () {
      expect(TradingSeries.centerForZoom(1, 0.5, 4, 0), 1 / 8);
      expect(TradingSeries.centerForZoom(1, 0.5, 4, 1), 7 / 8);
    });
  });
}
