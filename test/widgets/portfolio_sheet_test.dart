import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/bloc/portfolio/portfolio_cubit.dart';
import 'package:fuego/models/candlestick.dart';
import 'package:fuego/models/chain_registry.g.dart';
import 'package:fuego/models/portfolio.dart';
import 'package:fuego/widgets/trading/home_mode_bar.dart';
import 'package:fuego/widgets/trading/portfolio_sheet.dart';
import 'package:fuego/widgets/trading/trading_chart.dart';

const _price = FuegoPrice(
  xfgHeatRatio: 0.4,
  heatPegUsd: 1.58,
  xfgSpotUsd: 0.632,
  reserveXfg: 1,
  reserveHeat: 1,
  spotPrice: 1,
  height: 1,
);

PortfolioHolding _row(String key, double amount, {bool ok = true}) =>
    PortfolioHolding.fromChain(
      kChainByKey[key]!,
      amount: amount,
      reachable: ok,
    );

Widget _app(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('Fuego stays put and Portfolio is the door', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_app(HomeModeBar(onPortfolio: () => opened++)));
    expect(find.text('FUEGO'), findsOneWidget);
    await tester.tap(find.text('PORTFOLIO'));
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('the sheet prices only XFG and HEAT and marks history', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final portfolio = PortfolioState(
      price: _price,
      chainsLoaded: true,
      chainsTotal: 33,
      chainsDone: 33,
      accountAddress: '0xabc',
      holdings: {'eth': _row('eth', 0.5), 'cro': _row('cro', 0, ok: false)},
    );
    final valuation = PortfolioValuation.of(
      xfgAmount: 100,
      heatAmount: 50,
      price: _price,
    );

    await tester.pumpWidget(
      _app(
        PortfolioSheet(
          portfolio: portfolio,
          valuation: valuation,
          xfgAmount: 100,
          heatTotal: 50,
          heatUnlocked: 40,
          heatLocked: 10,
          heatKnown: true,
          masked: false,
          candles: [
            const Candlestick(
              time: 1700000000,
              open: 0.5,
              high: 0.6,
              low: 0.4,
              close: 0.55,
            ),
            const Candlestick(
              time: 1700086400,
              open: 0.55,
              high: 0.7,
              low: 0.5,
              close: 0.632,
            ),
          ],
          historyLoading: false,
          onClose: () {},
          onToggleMask: () {},
          onRefresh: () {},
          onManage: () {},
          onSend: () {},
          onReceive: () {},
          onMint: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // 100 × 0.632 + 50 × 1.58 = 142.20
    expect(find.text('\$142.20'), findsOneWidget);
    expect(find.textContaining('other chains unpriced'), findsOneWidget);
    expect(find.text('HISTORY'), findsOneWidget);
    expect(find.text('XFG'), findsWidgets);
    expect(find.text('ETH'), findsOneWidget);
    // Unpriced and unreadable both refuse a fake zero.
    expect(find.text('—'), findsWidgets);
    expect(find.text('\$0.00'), findsNothing);
    expect(find.text('SOL · no Solana key on this device'), findsOneWidget);
    expect(find.text('SEND'), findsOneWidget);
    expect(find.text('1M'), findsOneWidget);
  });

  testWidgets('chart collapses to the quote row', (tester) async {
    tester.view.physicalSize = const Size(390, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      _app(
        const TradingChart(
          candles: [
            Candlestick(
              time: 1700000000,
              open: 1,
              high: 1.2,
              low: 0.9,
              close: 1.1,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final openHeight = tester.getSize(find.byType(TradingChart)).height;
    await tester.tap(find.byIcon(Icons.expand_less));
    await tester.pumpAndSettle();
    final shutHeight = tester.getSize(find.byType(TradingChart)).height;
    expect(shutHeight, lessThan(openHeight));
    expect(shutHeight, lessThan(56));
    expect(find.text('HISTORY'), findsOneWidget);
  });
}
