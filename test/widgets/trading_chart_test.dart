import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/candlestick.dart';
import 'package:fuego/widgets/trading/trading_chart.dart';

/// 90 days from 2023-11-14, one point a day.
final List<Candlestick> _bars = List<Candlestick>.generate(
  90,
  (i) => Candlestick(
    time: 1700000000 + i * 86400,
    open: 1 + i * 0.01,
    high: 1 + i * 0.01,
    low: 1 + i * 0.01,
    close: 1 + i * 0.01,
    volume: 1000 + i * 100,
  ),
);

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

bool _isDim(Widget widget) =>
    widget is ColoredBox && widget.color == const Color(0x29000000);

/// A point inside the plot, below the 44px quote row.
Offset _plotPoint(WidgetTester tester, double fraction) {
  final rect = tester.getRect(find.byType(TradingChart));
  return Offset(
    rect.left + 1 + (rect.width - 53) * fraction,
    rect.top + 44 + 60,
  );
}

/// The date shown in the quote row while a crosshair is down, if any.
String? _shownDate(WidgetTester tester) {
  final date = RegExp(r'\d{4}-\d{2}-\d{2}');
  for (final text in tester.widgetList<Text>(find.byType(Text))) {
    final plain = text.data ?? text.textSpan?.toPlainText() ?? '';
    final match = date.firstMatch(plain);
    if (match != null) return match.group(0);
  }
  return null;
}

void main() {
  testWidgets('the plot canvas fills the chart height', (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(TradingChart(candles: _bars, plotHeight: 168)),
    );
    await tester.pumpAndSettle();

    final canvas = find.descendant(
      of: find.byType(TradingChart),
      matching: find.byType(CustomPaint),
    );
    expect(canvas, findsOneWidget);
    expect(tester.getSize(canvas), const Size(390, 168));
  });

  testWidgets('a hold dims the plot and reads price and volume', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(TradingChart(candles: _bars)));
    await tester.pumpAndSettle();

    expect(find.textContaining('Vol '), findsNothing);

    final gesture = await tester.startGesture(_plotPoint(tester, 0.4));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byWidgetPredicate(_isDim), findsOneWidget);
    expect(find.textContaining('Vol '), findsOneWidget);

    await gesture.up();
    await tester.pumpAndSettle();

    expect(find.byWidgetPredicate(_isDim), findsNothing);
    expect(find.textContaining('Vol '), findsNothing);
  });

  testWidgets('a scrub moves a light crosshair without dimming', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(TradingChart(candles: _bars)));
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(_plotPoint(tester, 0));
    await tester.pump();

    // Down on the left edge reads the first day, and the plot stays undimmed.
    expect(find.textContaining('2023-11-14'), findsOneWidget);
    expect(find.byWidgetPredicate(_isDim), findsNothing);
    expect(find.textContaining('Vol '), findsNothing);

    await gesture.moveTo(_plotPoint(tester, 0.5));
    await tester.pump();

    expect(find.textContaining('2023-11-14'), findsNothing);

    await gesture.up();
    await tester.pumpAndSettle();

    // Releasing returns the row to the window's move.
    expect(find.textContaining('2023-'), findsNothing);
    expect(find.byWidgetPredicate(_isDim), findsNothing);
  });

  testWidgets('a pinch zooms into real data, not a stretched render', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_app(TradingChart(candles: _bars)));
    await tester.pumpAndSettle();

    final before = await tester.startGesture(_plotPoint(tester, 0));
    await tester.pump();
    final firstDay = _shownDate(tester);
    await before.up();
    await tester.pumpAndSettle();
    expect(firstDay, '2023-11-14');

    final first = await tester.startGesture(_plotPoint(tester, 0.35));
    final second = await tester.startGesture(
      _plotPoint(tester, 0.65),
      pointer: 2,
    );
    await tester.pump();
    // Move both fingers symmetrically so the recognizer keeps its span
    // reference at the start of the pinch.
    for (var i = 0; i < 5; i++) {
      await first.moveBy(const Offset(-12, 0));
      await second.moveBy(const Offset(12, 0));
      await tester.pump();
    }
    await first.up();
    await second.up();
    await tester.pumpAndSettle();

    // The visible window now opens later than the series start.
    final scrub = await tester.startGesture(_plotPoint(tester, 0));
    await tester.pump();
    final zoomedDay = _shownDate(tester);
    await scrub.up();
    await tester.pumpAndSettle();

    expect(zoomedDay, isNotNull);
    expect(
      DateTime.parse(
        '${zoomedDay!}T00:00:00Z',
      ).isAfter(DateTime.parse('${firstDay!}T00:00:00Z')),
      isTrue,
      reason: 'a pinch should open the window after $firstDay, got $zoomedDay',
    );

    // Double-tap resets to the full window.
    await tester.tapAt(_plotPoint(tester, 0.5));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tapAt(_plotPoint(tester, 0.5));
    await tester.pumpAndSettle();

    final reset = await tester.startGesture(_plotPoint(tester, 0));
    await tester.pump();
    expect(_shownDate(tester), firstDay);
    await reset.up();
    await tester.pumpAndSettle();
  });

  testWidgets('a drag on the plot does not scroll the page', (tester) async {
    tester.view.physicalSize = const Size(390, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = ScrollController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: controller,
            children: [
              TradingChart(candles: _bars),
              const SizedBox(height: 600),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.drag(find.byType(TradingChart), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(controller.offset, 0);

    // The grab strip below the plot still scrolls the page.
    await tester.dragFrom(const Offset(200, 500), const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(controller.offset, greaterThan(0));
  });
}
