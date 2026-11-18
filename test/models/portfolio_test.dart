import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/bloc/portfolio/portfolio_cubit.dart';
import 'package:fuego/models/chain_registry.g.dart';
import 'package:fuego/models/portfolio.dart';

void main() {
  group('FuegoPrice', () {
    test('parses the daemon string doubles', () {
      final price = FuegoPrice.fromJson(const {
        'reserve_xfg': 50000000,
        'reserve_heat': 20000000,
        'spot_price': 4000000,
        'xfg_heat_ratio': '0.40000000',
        'heat_peg_usd': '1.5800',
        'xfg_spot_usd': '0.6320',
        'height': 12345,
      });
      expect(price.xfgHeatRatio, closeTo(0.4, 1e-9));
      expect(price.heatPegUsd, closeTo(1.58, 1e-9));
      expect(price.xfgSpotUsd, closeTo(0.632, 1e-9));
      expect(price.reserveXfg, 50000000);
      expect(price.height, 12345);
      expect(price.isPriced, isTrue);
    });

    test('tolerates numeric json and a dead pool', () {
      final price = FuegoPrice.fromJson(const {
        'xfg_heat_ratio': 0,
        'heat_peg_usd': 1.58,
        'xfg_spot_usd': 0,
      });
      expect(price.xfgSpotUsd, 0);
      expect(price.isPriced, isFalse);
    });

    test('missing fields do not throw', () {
      final price = FuegoPrice.fromJson(const {});
      expect(price.xfgSpotUsd, 0);
      expect(price.reserveHeat, 0);
    });
  });

  group('PortfolioValuation', () {
    const price = FuegoPrice(
      xfgHeatRatio: 0.4,
      heatPegUsd: 1.58,
      xfgSpotUsd: 0.632,
      reserveXfg: 0,
      reserveHeat: 0,
      spotPrice: 0,
      height: 0,
    );

    test('values XFG at spot and ΗΞΔŦ at the peg', () {
      final v = PortfolioValuation.of(
        xfgAmount: 100,
        heatAmount: 50,
        price: price,
      );
      expect(v.isPriced, isTrue);
      expect(v.xfgUsd, closeTo(63.2, 1e-9));
      expect(v.heatUsd, closeTo(79.0, 1e-9));
      expect(v.totalUsd, closeTo(142.2, 1e-9));
    });

    test('never invents a value without a priced snapshot', () {
      final v = PortfolioValuation.of(
        xfgAmount: 100,
        heatAmount: 50,
        price: null,
      );
      expect(v.isPriced, isFalse);
      expect(v.totalUsd, 0);
    });

    test('an unpriced pool contributes nothing', () {
      const dead = FuegoPrice(
        xfgHeatRatio: 0,
        heatPegUsd: 1.58,
        xfgSpotUsd: 0,
        reserveXfg: 0,
        reserveHeat: 0,
        spotPrice: 0,
        height: 0,
      );
      final v = PortfolioValuation.of(
        xfgAmount: 1000,
        heatAmount: 500,
        price: dead,
      );
      expect(v.isPriced, isFalse);
      expect(v.totalUsd, 0);
    });

    test('an unreadable ΗΞΔŦ balance is excluded, not valued at zero', () {
      final v = PortfolioValuation.of(
        xfgAmount: 100,
        heatAmount: 0,
        price: price,
        heatKnown: false,
      );
      expect(v.isPriced, isTrue);
      expect(v.heatKnown, isFalse);
      expect(v.heatUsd, 0);
      expect(v.totalUsd, closeTo(63.2, 1e-9));
    });
  });

  group('PortfolioHolding', () {
    test('carries the registry ticker, icon and mark colour', () {
      final chain = kChainByKey['eth']!;
      final holding = PortfolioHolding.fromChain(chain, amount: 1.5);
      expect(holding.ticker, 'ETH');
      expect(holding.name, 'Ethereum');
      expect(holding.icon, chain.icon);
      expect(holding.color.toARGB32(), 0xFF627EEA);
      expect(holding.isHeld, isTrue);
    });

    test('unreadable chains are not reported as empty wallets', () {
      final holding = PortfolioHolding.fromChain(
        kChainByKey['arb']!,
        reachable: false,
        note: 'RPC unreachable',
      );
      expect(holding.reachable, isFalse);
      expect(holding.isHeld, isFalse);
      expect(holding.note, 'RPC unreachable');
    });

    test('zero balance is not a holding', () {
      final holding = PortfolioHolding.fromChain(kChainByKey['base']!);
      expect(holding.isHeld, isFalse);
    });
  });

  group('PortfolioState', () {
    PortfolioHolding row(String key, double amount) =>
        PortfolioHolding.fromChain(kChainByKey[key]!, amount: amount);

    test('held chains sort first, richest first among themselves', () {
      final state = PortfolioState(
        holdings: {
          'eth': row('eth', 0),
          'arb': row('arb', 0.5),
          'base': row('base', 2),
        },
      );
      expect(state.allHoldings.map((h) => h.chainKey).toList(), [
        'base',
        'arb',
        'eth',
      ]);
      expect(state.heldChainCount, 2);
      expect(state.heldHoldings.first.chainKey, 'base');
    });

    test('counts unreadable chains separately', () {
      final state = PortfolioState(
        holdings: {
          'eth': row('eth', 0),
          'arb': PortfolioHolding.fromChain(
            kChainByKey['arb']!,
            reachable: false,
          ),
        },
      );
      expect(state.unreadableChainCount, 1);
      expect(state.heldChainCount, 0);
    });
  });

  group('groupThousands', () {
    test('groups with a thin space and keeps the fraction', () {
      expect(groupThousands('1234567.89'), '1\u2009234\u2009567.89');
      expect(groupThousands('12.5'), '12.5');
      expect(groupThousands('0.0004'), '0.0004');
    });
  });
}
