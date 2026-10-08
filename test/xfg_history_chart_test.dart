import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/services/hearth_spot_history_service.dart';
import 'package:fuego/services/price_history_service.dart';
import 'package:fuego/widgets/fuego_chart.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled XFG history retains every supplied observation', () async {
    final candles = await PriceHistoryService().loadAll();

    expect(candles, hasLength(2630));
    expect(candles.first.time, 1549515600);
    expect(candles.last.time, 1776729600);
    expect(candles.last.close, 0.00900725);
    expect(candles.every((candle) => candle.close > 0), isTrue);
    expect(
      candles.map((candle) => candle.time).toSet(),
      hasLength(candles.length),
    );
  });

  testWidgets('full archive is visible by default and range controls work', (
    tester,
  ) async {
    final candles = await PriceHistoryService().loadAll();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 320,
            child: FuegoChart(
              candles: candles,
              contextNote: 'Not the selected pair rate',
            ),
          ),
        ),
      ),
    );

    expect(find.text('XFG/USD · historical'), findsOneWidget);
    expect(find.textContaining('2019-02-07 — 2026-04-21'), findsOneWidget);
    expect(find.textContaining('archive ends 2026-04-21'), findsOneWidget);
    expect(
      find.textContaining('Not the selected pair rate · not live'),
      findsOneWidget,
    );

    await tester.tap(find.text('1Y'));
    await tester.pump();
    expect(find.textContaining('2025-04-21 — 2026-04-21'), findsOneWidget);

    await tester.drag(
      find.byKey(const Key('xfg-history-plot')),
      const Offset(120, 0),
    );
    await tester.pump();
    expect(find.textContaining('2025-04-21 — 2026-04-21'), findsNothing);

    await tester.tap(find.text('ALL'));
    await tester.pump();
    expect(find.textContaining('2019-02-07 — 2026-04-21'), findsOneWidget);

    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(const Key('xfg-history-plot'))),
        scrollDelta: const Offset(0, -240),
      ),
    );
    await tester.pump();
    expect(find.textContaining('2019-02-07 — 2026-04-21'), findsNothing);
  });

  testWidgets('history panel loads the bundled series', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: XfgHistoryPanel(contextNote: 'Not the selected pair rate'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('XFG/USD · historical'), findsOneWidget);
    expect(find.textContaining('2019-02-07 — 2026-04-21'), findsOneWidget);
    expect(
      find.textContaining('Not the selected pair rate · not live'),
      findsOneWidget,
    );
  });

  testWidgets('Hearth contains only observed pool spots', (tester) async {
    final archive = await PriceHistoryService().loadAll();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 320,
            child: FuegoChart(
              candles: archive,
              contextNote: 'Pool spots sampled only while Hearth is open',
              quote: XfgHistoryQuote.heat,
              observedSpots: const [
                HearthSpotObservation(time: 1790985600, heatPerXfg: 0.1),
              ],
            ),
          ),
        ),
      ),
    );

    expect(find.text('XFG/HΞΔŦ · pool spot'), findsOneWidget);
    expect(find.textContaining('archive ends'), findsNothing);
    expect(find.textContaining('2019-02-07'), findsNothing);
    expect(find.textContaining('backcast'), findsNothing);
    expect(
      find.textContaining('Observed pool spot only · missing days left blank'),
      findsOneWidget,
    );
    expect(find.textContaining('1 local daily samples'), findsOneWidget);
  });

  testWidgets('Hearth has an honest empty state before the first pool sample', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: XfgHistoryPanel(
              contextNote: 'Pool spots sampled only while Hearth is open',
              quote: XfgHistoryQuote.heat,
            ),
          ),
        ),
      ),
    );

    expect(find.text('No Hearth pool observations yet'), findsOneWidget);
    expect(find.text('XFG/USD · historical'), findsNothing);
  });
}
