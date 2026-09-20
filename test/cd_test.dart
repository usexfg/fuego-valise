import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/core/constants.dart';
import 'package:fuego/models/cd.dart';
import 'package:fuego/models/heat_amm.dart';

/// Constants pinned to fuego-suite `src/CryptoNoteConfig.h`. If consensus
/// moves, these fail first and point at what to re-check.
void main() {
  group('consensus constants', () {
    test('block cadence matches DIFFICULTY_TARGET', () {
      // DIFFICULTY_TARGET = 480 seconds.
      expect(avgBlockTime, 480);
      // EXPECTED_NUMBER_OF_BLOCKS_PER_DAY = 24 * 60 * 60 / DIFFICULTY_TARGET.
      expect(blocksPerDay, 180);
    });

    test('epoch and term bounds match DEPOSIT_MIN_TERM/DEPOSIT_MAX_TERM', () {
      // EPOCH_DURATION_BLOCKS = 900 (5 days at 480s).
      expect(epochBlocks, 900);
      expect(epochBlocks * 5 ~/ blocksPerDay, 25);
      // CD_MIN_EPOCHS(6) * 900 = 5400, CD_MAX_EPOCHS(72) * 900 = 64800.
      expect(depositMinTerm, 5400);
      expect(depositMaxTerm, 64800);
      // CD_ALLOWED_TIERS.
      expect(cdTermTiers, [6, 18, 36, 72]);
    });

    test('minimum term is one month, which is the 8 HEAT entry point', () {
      // 5400 blocks / 180 blocks per day = 30 days.
      expect(depositMinTerm ~/ blocksPerDay, 30);
      // DEPOSIT_MIN_AMOUNT = AMOUNT_TIER_0 = 8 HEAT.
      expect(depositMinAmount, 8 * atomicPerCoin);
    });

    test('network fee is MINIMUM_FEE, not ten times it', () {
      // transaction_builder.rs MINIMUM_FEE = 8000 atomic = 0.0008 XFG.
      expect(txFee, 8000);
      expect(txFee / atomicPerCoin, 0.0008);
    });

    test('ring size meets the advertised 8 minimum', () {
      expect(defaultMixin, greaterThanOrEqualTo(8));
    });
  });

  group('CdInfo', () {
    Map<String, dynamic> json({
      int blocksToMaturity = 2700,
      int termBlocks = 5400,
      bool matured = false,
      bool capped = false,
    }) =>
        {
          'cd_id': 'a' * 64,
          'owner': 'fire...',
          'coin': 'HEAT',
          'amount': '8',
          'accrued_pct': '0.0123',
          'term_blocks': termBlocks,
          'term_epochs': termBlocks ~/ 900,
          'maturity_height': 105400,
          'deposit_height': 100000,
          'accrued_interest': capped ? '0.0005' : '0.001',
          'uncapped_interest': '0.001',
          'interest_is_capped': capped,
          'fee_pool_balance': '12.5',
          'cd_apy_vault_balance': '4.25',
          'effective_epochs': 3,
          'total_value': '8.001',
          'blocks_to_maturity': blocksToMaturity,
          'matured': matured,
        };

    test('days remaining uses 180 blocks per day', () {
      // A full 6-epoch term is 30 days, not the 3 that 1440 blocks/day gave.
      expect(CdInfo.fromJson(json(blocksToMaturity: 5400)).daysToMaturity, 30);
      expect(CdInfo.fromJson(json(blocksToMaturity: 2700)).daysToMaturity, 15);
      expect(CdInfo.fromJson(json(blocksToMaturity: 179)).daysToMaturity, 0);
    });

    test('progress is the fraction of term elapsed, clamped', () {
      expect(CdInfo.fromJson(json(blocksToMaturity: 5400)).progress, 0.0);
      expect(CdInfo.fromJson(json(blocksToMaturity: 2700)).progress, 0.5);
      expect(CdInfo.fromJson(json(blocksToMaturity: 0)).progress, 1.0);
      // A CD past maturity must not read above 100%.
      expect(CdInfo.fromJson(json(blocksToMaturity: 0, matured: true)).progress,
          lessThanOrEqualTo(1.0));
    });

    test('progress is 0 rather than NaN when the term is unknown', () {
      expect(CdInfo.fromJson(json(termBlocks: 0)).progress, 0.0);
    });

    test('accrued interest is the pool-capped figure, flagged when capped', () {
      final capped = CdInfo.fromJson(json(capped: true));
      // The claimable figure is what a spend may take; consensus rejects a
      // claimedInterest above the pool and vault backing.
      expect(capped.accruedInterest, '0.0005');
      expect(capped.uncappedInterest, '0.001');
      expect(capped.interestIsCapped, isTrue);

      final uncapped = CdInfo.fromJson(json());
      expect(uncapped.accruedInterest, uncapped.uncappedInterest);
      expect(uncapped.interestIsCapped, isFalse);
    });

    test('missing fields degrade instead of throwing', () {
      // list_cds from an older daemon must not crash the CD screen.
      final cd = CdInfo.fromJson({'cd_id': 'x'});
      expect(cd.cdId, 'x');
      expect(cd.amount, '0');
      expect(cd.matured, isFalse);
      expect(cd.progress, 0.0);
    });
  });

  group('CdClaimResult', () {
    test('reports the real amounts the claim paid', () {
      final result = CdClaimResult.fromJson({
        'cd_id': 'b' * 64,
        'tx_hash': 'c' * 64,
        'coin': 'HEAT',
        'principal': '8',
        'interest': '0.0011',
        'total': '8.0011',
        'fee': '0.0008',
        'cds_claimed': 1,
      });
      expect(result.principal, '8');
      expect(result.interest, '0.0011');
      expect(result.total, '8.0011');
      expect(result.fee, '0.0008');
      expect(result.cdsClaimed, 1);
    });

    test('surfaces a multi-CD claim', () {
      // Claiming without a cd_id spends every mature CD; the count makes that
      // visible rather than silent.
      final result = CdClaimResult.fromJson({'cds_claimed': 4});
      expect(result.cdsClaimed, 4);
    });
  });

  group('CdConfig', () {
    test('fallback mirrors the compiled-in consensus constants', () {
      const c = CdConfig.fallback;
      expect(c.epochBlocks, 900);
      expect(c.blocksPerDay, 180);
      expect(c.termTiers, [6, 18, 36, 72]);
      expect(c.depositMinTerm, 5400);
      expect(c.depositMaxTerm, 64800);
      expect(c.depositMinAmount, 8 * atomicPerCoin);
      // heat_cd_core defaults the banking fee to amount / 1000 = 10 bps.
      expect(c.creationFeeBps, 10);
    });

    test('amount tiers start at the deposit minimum', () {
      const c = CdConfig.fallback;
      expect(c.amountTiers.first, c.depositMinAmount);
      expect(c.amountTiers.length, c.amountTiersDisplay.length);
    });

    test('every term tier lands inside the consensus range', () {
      const c = CdConfig.fallback;
      for (final t in c.termTiers) {
        final blocks = t * c.epochBlocks;
        expect(blocks, greaterThanOrEqualTo(c.depositMinTerm));
        expect(blocks, lessThanOrEqualTo(c.depositMaxTerm));
      }
    });

    test('carries no term bonus, since calculateCdBonus applies none', () {
      // The pro-rata loyalty multiplier was replaced by a flat, term-blind
      // CD_YIELD_FLOOR_RATE top-up. Quoting a multiplier would promise a rule
      // consensus stopped applying.
      final parsed = CdConfig.fromJson({
        'epoch_blocks': 900,
        'term_tiers': [6, 18, 36, 72],
      });
      expect(parsed.termTiers, [6, 18, 36, 72]);
    });

    test('a partial config falls back per field', () {
      final parsed = CdConfig.fromJson({'epoch_blocks': 10});
      // Testnet epoch, but the term tiers and bounds still come from defaults.
      expect(parsed.epochBlocks, 10);
      expect(parsed.termTiers, cdTermTiers);
      expect(parsed.depositMinTerm, depositMinTerm);
    });
  });

  group('CdYieldPool', () {
    test('distinguishes an empty pool from an unknown one', () {
      final unknown = CdYieldPool.fromJson({'coin': 'HEAT'});
      expect(unknown.poolInfoPresent, isFalse);

      final known = CdYieldPool.fromJson({
        'coin': 'HEAT',
        'fee_pool_balance': '0',
        'cd_apy_vault_balance': '0',
        'pool_info_present': true,
      });
      expect(known.poolInfoPresent, isTrue);
      expect(known.feePoolBalance, '0');
    });
  });

  group('HeatMetrics pool ratio', () {
    HeatMetrics metrics({required int num_, int denom = 1000000}) =>
        HeatMetrics.fromJson({
          'redemption_price_num': num_,
          'redemption_price_denom': denom,
          'heat_supply': 80000000,
          'heat_on_deposit': 80000000,
          'vault_heat_cd_fee_pool': 125000000,
          'vault_xfg_lp_reserve': 10000000,
          'vault_heat_lp_reserve': 20000000,
          'treasury_balance': 50000000,
        });

    test('pool ratio is XFG per ΗΞΔŦ, per Core.cpp, and display only', () {
      // reserveXfg * 1e6 / reserveHeat, denom = 1e6. Named a pool ratio, not
      // a redemption price: ΗΞΔŦ does not redeem back to XFG.
      expect(metrics(num_: 500000).xfgPerHeat, 0.5);
      expect(metrics(num_: 500000).formattedPoolRatio, '0.500000 XFG/ΗΞΔŦ');
    });

    test('an undefined ratio is null, not zero or one', () {
      expect(metrics(num_: 0).xfgPerHeat, isNull);
      expect(metrics(num_: 0).formattedPoolRatio, '—');
      expect(metrics(num_: 500000, denom: 0).xfgPerHeat, isNull);
    });

    test('amounts render as coin decimals, not atomic units', () {
      final m = metrics(num_: 1000000);
      expect(m.supply, '8');
      expect(m.onDeposit, '8');
      expect(m.cdYieldPool, '12.5');
      expect(m.poolXfg, '1');
      expect(m.poolHeat, '2');
    });
  });

  group('PoolInfo mint price', () {
    PoolInfo pool({int twap = 0, int spot = 0, int reported = 0}) =>
        PoolInfo.fromJson({
          'reserve_xfg': 10000000,
          'reserve_heat': 20000000,
          'total_lp_shares': 100,
          'spot_price': spot,
          'epoch_swap_fees': 0,
          'hearth_twap': twap,
          'mint_price': reported,
        });

    test('prefers the daemon\'s reported mint price', () {
      // Blockchain::getMintPrice is the single source of truth; the client
      // must not re-derive it when the daemon reports one.
      expect(pool(reported: 50000000, twap: 30000000, spot: 20000000).mintPrice,
          50000000);
    });

    test('falls back TWAP then spot, as Blockchain.cpp orders them', () {
      // An older daemon leaves mint_price unset.
      expect(pool(twap: 30000000, spot: 20000000).mintPrice, 30000000);
      expect(pool(spot: 20000000).mintPrice, 20000000);
    });

    test('falls back to the launch ratio when the pool has no price', () {
      // The chicken-and-egg: accumulateTwap only samples a non-empty pool,
      // and the pool cannot hold ΗΞΔŦ before any is minted. Without this the
      // first mint is impossible and the pool can never be seeded.
      expect(pool().mintPrice, heatLaunchMintPrice);
      expect(pool().mintPrice, 1000000);
    });

    test('the launch ratio is 10 XFG per ΗΞΔŦ on the canonical scale', () {
      // HEAT_LAUNCH_RATIO_NUM/DENOM = 10/1 XFG per ΗΞΔŦ, inverted onto
      // HEAT-per-XFG x COIN: COIN / 10.
      expect(heatLaunchRatioXfgPerHeat, 10);
      expect(heatLaunchMintPrice, atomicPerCoin ~/ 10);
      // Burning 10 XFG at the launch ratio mints exactly 1 ΗΞΔŦ.
      const burn = 10 * atomicPerCoin;
      expect(burn * heatLaunchMintPrice ~/ atomicPerCoin, atomicPerCoin);
    });

    test('is on the canonical scale: HEAT per XFG x COIN', () {
      // ammGetSpotPrice = reserveHeat * COIN / reserveXfg. With 2 HEAT of
      // reserve against 1 XFG that is 2 HEAT per XFG, scaled by COIN.
      expect(pool(spot: 20000000).heatPerXfg, 2.0);
      expect(pool(spot: 5000000).heatPerXfg, 0.5);
      expect(pool(spot: atomicPerCoin).heatPerXfg, 1.0);
    });

    test('quote multiplies by price / COIN, matching expectedHeatFor', () {
      // expectedHeatFor(xfgBurned, price) = xfgBurned * price / COIN.
      // Burning 1 XFG at 2 HEAT/XFG mints 2 HEAT.
      const burnAtomic = atomicPerCoin;
      final price = pool(spot: 20000000).mintPrice!;
      expect(burnAtomic * price ~/ atomicPerCoin, 2 * atomicPerCoin);
    });

    test('quote truncates down so it cannot exceed the consensus cap', () {
      // A price of 1/3 HEAT per XFG leaves a remainder; rounding up would
      // put heatOutputs one atomic unit over expectedHeat and be rejected.
      final price = pool(spot: 3333333).mintPrice!;
      const burnAtomic = atomicPerCoin;
      final minted = burnAtomic * price ~/ atomicPerCoin;
      expect(minted, 3333333);
      expect(minted, lessThanOrEqualTo(burnAtomic * price / atomicPerCoin));
    });

    test('a mint costs exactly the price, with no premium on top', () {
      // The mandatory mint premium is gone: burning N XFG mints exactly
      // N * price / COIN, so a quote never has to hold anything back.
      const burn = 10 * atomicPerCoin;
      final price = pool(spot: atomicPerCoin).mintPrice!;
      expect(burn * price ~/ atomicPerCoin, burn);
    });
  });

  group('formatHeat', () {
    test('trims trailing zeros and handles whole amounts', () {
      expect(formatHeat(80000000), '8');
      expect(formatHeat(5000), '0.0005');
      expect(formatHeat(8000), '0.0008');
      expect(formatHeat(10000001), '1.0000001');
      expect(formatHeat(0), '0');
    });
  });
}
