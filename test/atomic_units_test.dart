import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/core/constants.dart';
import 'package:fuego/models/heat_amm.dart';

/// XFG and ΗΞΔŦ both use COIN = 10^7 (fuego-suite `CryptoNoteConfig.h`:
/// "1 HEAT = 10^CRYPTONOTE_DISPLAY_DECIMAL_POINT = 10,000,000 atomic").
void main() {
  group('parseAtomic', () {
    test('is exact where (x * 1e7).toInt() truncated', () {
      // Each of these loses one atomic unit under double multiplication +
      // truncation; ~5.5% of full-precision 7-decimal amounts do.
      expect(parseAtomic('553.8829718'), 5538829718);
      expect(parseAtomic('341.1833895'), 3411833895);
      expect(parseAtomic('69.7086885'), 697086885);
      expect(parseAtomic('22.5810525'), 225810525);
      expect(parseAtomic('156.6099205'), 1566099205);
    });

    test('handles the ordinary cases', () {
      expect(parseAtomic('1.5'), 15000000);
      expect(parseAtomic('0.0000001'), 1);
      expect(parseAtomic('0'), 0);
      expect(parseAtomic('100'), 1000000000);
      expect(parseAtomic('1.'), 10000000);
      expect(parseAtomic('.5'), 5000000);
    });

    test('rejects what it cannot represent instead of silently zeroing', () {
      // int.tryParse('1.5') is null, so the old AMM client sent 0 for every
      // decimal amount the user typed.
      expect(parseAtomic('1.12345678'), isNull, reason: '8 dp > 7');
      expect(parseAtomic('abc'), isNull);
      expect(parseAtomic(''), isNull);
      expect(parseAtomic('.'), isNull);
      expect(parseAtomic('-1'), isNull);
    });

    test('honours a non-default decimal count for counterparty chains', () {
      expect(parseAtomic('1', decimals: 18), 1000000000000000000);
      expect(parseAtomic('1.5', decimals: 8), 150000000);
      expect(parseAtomic('0.123456789', decimals: 8), isNull);
    });

    test('refuses amounts past the uint64 the daemon carries', () {
      // ctr_amount is a uint64 on the wire and a 64-bit int in Dart. On an
      // 18-decimal chain that ceiling arrives at ~9.22 tokens — better a
      // refusal than a wrapped value.
      expect(parseAtomic('9.22', decimals: 18), 9220000000000000000);
      expect(parseAtomic('9.3', decimals: 18), isNull);
      expect(parseAtomic('10', decimals: 18), isNull);
      // 8-decimal chains have plenty of headroom.
      expect(parseAtomic('21000000', decimals: 8), 2100000000000000);
    });
  });

  group('atomicToDisplay', () {
    test('round-trips with parseAtomic', () {
      for (final v in ['0.0000001', '1.5', '553.8829718', '100.0000000']) {
        final a = parseAtomic(v);
        expect(a, isNotNull);
        expect(parseAtomic(atomicToDisplay(a!)), a);
      }
    });

    test('pads the fraction to full precision', () {
      expect(atomicToDisplay(1), '0.0000001');
      expect(atomicToDisplay(10000000), '1.0000000');
    });
  });

  test('txFee matches consensus MINIMUM_FEE (8000 = 0.0008 XFG)', () {
    // MINIMUM_FEE = MINIMUM_FEE_8KH = 8000. Screens that hardcoded 0.008 were
    // quoting the retired V2 fee, ten times too high.
    expect(txFee, 8000);
    expect(txFeeXfg, closeTo(0.0008, 1e-12));
    expect(parseAtomic(txFeeXfg.toStringAsFixed(7)), txFee);
  });

  group('PoolInfo scaling', () {
    PoolInfo pool({
      required int xfg,
      required int heat,
      required int spot,
    }) =>
        PoolInfo.fromJson({
          'reserve_xfg': xfg,
          'reserve_heat': heat,
          'total_lp_shares': 1000,
          'spot_price': spot,
          'epoch_swap_fees': 0,
          'hearth_twap': 0,
          'status': 'OK',
        });

    test('spot_price is HEAT per XFG scaled by COIN', () {
      // Genesis seed: HEARTH_INITIAL_XFG 10,000 XFG : HEARTH_INITIAL_HEAT
      // 1,000 HEAT — a 10:1 ratio, so 0.1 HEAT per XFG.
      final p = pool(
        xfg: 10000 * 10000000,
        heat: 1000 * 10000000,
        spot: 1000000, // 0.1 * COIN
      );
      expect(p.heatPerXfg, closeTo(0.1, 1e-9));
      expect(p.xfgPerHeat, closeTo(10.0, 1e-9));
      expect(p.reserveHeatPerXfg, closeTo(0.1, 1e-9));
      expect(p.isSeeded, isTrue);
      expect(p.xfgBalance, '10000.0000000');
      expect(p.heatBalance, '1000.0000000');
    });

    test('an unseeded pool reports no rate rather than a stand-in', () {
      final p = pool(xfg: 0, heat: 0, spot: 0);
      expect(p.isSeeded, isFalse);
      expect(p.price, '—');
      expect(p.reserveHeatPerXfg, isNull);
    });
  });

  group('HeatMetrics', () {
    test('APY is null when the daemon does not report a rate', () {
      // on_get_heat_metrics assigns every field EXCEPT redemption_rate_num
      // and redemption_rate_denom, so a zero denominator means "unreported".
      final m = HeatMetrics.fromJson({'status': 'OK'});
      expect(m.currentApy, isNull);
      expect(m.cdYield, '—');
    });

    test('reports the rate when the daemon fills it', () {
      final m = HeatMetrics.fromJson({
        'redemption_rate_num': 5,
        'redemption_rate_denom': 100,
        'status': 'OK',
      });
      expect(m.currentApy, closeTo(5.0, 1e-9));
      expect(m.cdYield, '5.00%');
    });

    test('balances render in display units', () {
      final m = HeatMetrics.fromJson({
        'heat_supply': 12345000000,
        'treasury_balance': 10000000,
        'status': 'OK',
      });
      expect(m.supply, '1234.5000000');
      expect(m.treasury, '1.0000000');
    });
  });

  group('AmmQuote', () {
    test('output and fee render in display units, impact as percent', () {
      final q = AmmQuote.fromJson({
        'expected_output': 15000000,
        'price_impact_bps': 125,
        'fee': 100000,
        'status': 'OK',
      });
      expect(q.outputAtomic, 15000000);
      expect(q.outputAmount, '1.5000000');
      expect(q.feeDisplay, '0.0100000');
      expect(q.priceImpactPercent, closeTo(1.25, 1e-9));
      expect(q.priceImpact, '1.25%');
    });

    test('a zero output is surfaced, not printed as 0', () {
      final q = AmmQuote.fromJson({'status': 'OK'});
      expect(q.outputAtomic, isNull);
      expect(q.outputAmount, '—');
    });
  });
}
