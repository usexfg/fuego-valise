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
  });
}
