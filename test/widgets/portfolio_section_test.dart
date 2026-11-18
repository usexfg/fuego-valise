import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/bloc/portfolio/portfolio_cubit.dart';
import 'package:fuego/models/chain_registry.g.dart';
import 'package:fuego/models/portfolio.dart';
import 'package:fuego/utils/theme.dart';
import 'package:fuego/widgets/portfolio/heat_plate.dart';
import 'package:fuego/widgets/portfolio/other_assets_drawer.dart';
import 'package:fuego/widgets/portfolio/portfolio_header.dart';

const _price = FuegoPrice(
  xfgHeatRatio: 0.4,
  heatPegUsd: 1.58,
  xfgSpotUsd: 0.632,
  reserveXfg: 50000000,
  reserveHeat: 20000000,
  spotPrice: 4000000,
  height: 120000,
);

PortfolioHolding _row(String key, double amount, {bool ok = true}) =>
    PortfolioHolding.fromChain(
      kChainByKey[key]!,
      amount: amount,
      reachable: ok,
    );

PortfolioState _state({bool withAccount = true}) => PortfolioState(
  price: _price,
  chainsLoaded: true,
  chainsTotal: 33,
  chainsDone: 33,
  accountName: withAccount ? 'Treasury' : null,
  accountAddress: withAccount
      ? '0x8f3a5b0d21c4e7f9a6b8c1d2e3f4a5b6c7d8e9f0'
      : null,
  savedAccountCount: withAccount ? 1 : 0,
  holdings: {
    'eth': _row('eth', 0.4821),
    'arb': _row('arb', 12.5),
    'poly': _row('poly', 340.75),
    'base': _row('base', 0),
    'cro': _row('cro', 0, ok: false),
  },
);

Widget _harness(List<Widget> children) => MaterialApp(
  debugShowCheckedModeBanner: false,
  home: Scaffold(
    backgroundColor: AppTheme.backgroundColor,
    body: ListView(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 24),
      children: children,
    ),
  ),
);

Future<void> _pumpSection(
  WidgetTester tester, {
  required PortfolioState state,
  bool masked = false,
  int height = 1000,
}) async {
  tester.view.physicalSize = Size(390, height.toDouble());
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final valuation = PortfolioValuation.of(
    xfgAmount: 12345.6789,
    heatAmount: 2500.5,
    price: _price,
  );

  await tester.pumpWidget(
    _harness([
      PortfolioHeader(
        valuation: valuation,
        masked: masked,
        heldChainCount: state.heldChainCount,
        isRefreshing: false,
        onRefresh: () {},
      ),
      const SizedBox(height: 12),
      HeatPlate(
        total: 2500.5,
        unlocked: 2400,
        locked: 100.5,
        masked: masked,
        pegUsd: 1.58,
        onMint: () {},
      ),
      const SizedBox(height: 10),
      OtherAssetsDrawer(
        state: state,
        masked: masked,
        onExpand: () {},
        onRefresh: () {},
        onManage: () {},
      ),
    ]),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('portfolio strata', () {
    testWidgets('XFG heading sits above the ΗΞΔŦ reserve and chain drawer', (
      tester,
    ) async {
      await _pumpSection(tester, state: _state());

      expect(tester.takeException(), isNull);
      final header = tester.getTopLeft(find.text('PORTFOLIO')).dy;
      final heat = tester.getTopLeft(find.text('ΗΞΔŦ')).dy;
      final chains = tester.getTopLeft(find.text('OTHER ASSETS')).dy;
      expect(header, lessThan(heat));
      expect(heat, lessThan(chains));
    });

    testWidgets('prices XFG and ΗΞΔŦ, never the unpriced chains', (
      tester,
    ) async {
      await _pumpSection(tester, state: _state());

      // 12345.6789 × 0.632 + 2500.5 × 1.58 = 11 753.26 (house thin-space grouping)
      expect(find.text('\$11\u2009753.26'), findsOneWidget);
      expect(find.text('≈ \$3\u2009950.79'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
    });

    testWidgets('drawer opens to the chains that hold something', (
      tester,
    ) async {
      await _pumpSection(tester, state: _state());
      expect(find.text('PLY'.replaceAll('PLY', 'POLY')), findsNothing);

      await tester.tap(find.text('OTHER ASSETS'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('POLY'), findsOneWidget);
      expect(find.text('ARB'), findsOneWidget);
      expect(find.text('340.7500'), findsOneWidget);
      expect(find.text('12.5000'), findsOneWidget);
      // Zero-balance chains stay collapsed by default.
      expect(find.text('BASE'), findsNothing);
    });

    testWidgets('unreadable chains read as unknown, not zero', (tester) async {
      await _pumpSection(tester, state: _state());
      await tester.tap(find.text('OTHER ASSETS'));
      await tester.pumpAndSettle();

      expect(find.text('1 chain unreadable — balance unknown'), findsOneWidget);
      expect(find.text('SHOW ALL 33 CHAINS'), findsOneWidget);
    });

    testWidgets('showing all 33 chains lists the empties too', (tester) async {
      await _pumpSection(tester, state: _state(), height: 2400);
      await tester.tap(find.text('OTHER ASSETS'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('SHOW ALL 33 CHAINS'));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('BASE'), findsOneWidget);
      expect(find.text('CRO'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('HIDE EMPTY CHAINS'), findsOneWidget);
    });

    testWidgets('masking hides the heading, the reserve and chain amounts', (
      tester,
    ) async {
      await _pumpSection(tester, state: _state(), masked: true);
      await tester.tap(find.text('OTHER ASSETS'));
      await tester.pumpAndSettle();

      expect(find.text('\$11\u2009753.26'), findsNothing);
      expect(find.text('••••••'), findsOneWidget);
      expect(find.text('2 500.5000'), findsNothing);
      expect(find.text('••••'), findsWidgets);
      expect(find.text('340.7500'), findsNothing);
    });

    testWidgets('drawer explains the SOL gap instead of faking a balance', (
      tester,
    ) async {
      await _pumpSection(tester, state: _state());
      await tester.tap(find.text('OTHER ASSETS'));
      await tester.pumpAndSettle();

      expect(
        find.text('SOL · no Solana key in this wallet yet'),
        findsOneWidget,
      );
    });

    testWidgets('no EVM wallet points at wallet creation', (tester) async {
      await _pumpSection(tester, state: _state(withAccount: false));
      expect(find.text('33 chains · no EVM wallet'), findsOneWidget);

      await tester.tap(find.text('OTHER ASSETS'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No EVM wallet on this device'),
        findsOneWidget,
      );
      expect(find.text('CREATE WALLET'), findsOneWidget);
    });

    testWidgets('an unpriced portfolio claims no value', (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _harness([
          const PortfolioHeader(
            valuation: PortfolioValuation.unpriced(),
            masked: false,
            heldChainCount: 0,
            isRefreshing: false,
            priceError: 'Live price unavailable',
          ),
          const SizedBox(height: 12),
          HeatPlate(
            total: 0,
            unlocked: 0,
            locked: 0,
            masked: false,
            onMint: () {},
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('—'), findsOneWidget);
      expect(find.text('UNPRICED'), findsOneWidget);
      expect(find.text('Live price unavailable'), findsOneWidget);
      expect(find.text('EST.'), findsNothing);
      expect(find.text('MINT'), findsOneWidget);
    });

    testWidgets('a walletd that cannot report ΗΞΔŦ says so', (tester) async {
      tester.view.physicalSize = const Size(390, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _harness([
          PortfolioHeader(
            valuation: PortfolioValuation.of(
              xfgAmount: 1000,
              heatAmount: 0,
              price: _price,
              heatKnown: false,
            ),
            masked: false,
            heldChainCount: 0,
            isRefreshing: false,
          ),
          const SizedBox(height: 12),
          HeatPlate(
            total: 0,
            unlocked: 0,
            locked: 0,
            masked: false,
            available: false,
            pegUsd: 1.58,
            onMint: () {},
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // Total covers XFG only (1000 × 0.632), never an invented ΗΞΔŦ zero value.
      expect(find.text('\$632.00'), findsOneWidget);
      expect(find.text('XFG priced · ΗΞΔŦ balance unreadable'), findsOneWidget);
      // The reserve reads as unknown, and only the headline plus two sub-rows
      // are dashes.
      expect(find.text('—'), findsNWidgets(3));
      expect(
        find.text('ΗΞΔŦ balance not reported by this wallet build'),
        findsOneWidget,
      );
    });
  });
}
