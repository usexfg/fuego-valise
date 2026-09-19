import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/chain_info.dart';
import 'package:fuego/models/swap_models.dart';
import 'package:fuego/services/swap_daemon_client.dart';

/// Ground truth for everything here is fuego-suite:
///   src/SwapDaemon/SwapTypes.h   — `enum class SwapPair` (ids 0-28)
///   src/SwapDaemon/SwapTypes.cpp — `swapPairFromString` / `swapPairToString`
///   src/SwapDaemon/SwapDaemon.cpp — `registerChain(SwapPair::…)`
///
/// The previous version of this file asserted the *tables* (ids, tickers,
/// decimals) and passed while every runtime *lookup* that consumed them was
/// broken. These tests exercise the lookups.
void main() {
  group('SwapPairSdk mirrors the C++ SwapPair enum', () {
    test('covers ids 0-28 with no gaps', () {
      final ids = SwapPairSdk.values.map((p) => p.id).toList()..sort();
      expect(ids, List<int>.generate(29, (i) => i));
    });

    test('ids and tickers match fuego-suite', () {
      const expected = <int, String>{
        0: 'SOL',
        1: 'ETH',
        2: 'XMR',
        3: 'BCH',
        4: 'ARB',
        5: 'BASE',
        6: 'KMD',
        7: 'BNB',
        8: 'DCR',
        9: 'BTC',
        10: 'LTC',
        11: 'POLY',
        12: 'GLEEC',
        13: 'RHC',
        14: 'AVAX',
        15: 'CRO',
        16: 'BOB',
        17: 'SIA',
        18: 'UNI',
        19: 'XPL',
        20: 'DOGE',
        21: 'DASH',
        22: 'ZEC',
        23: 'PLS',
        24: 'ZANO',
        25: 'MON',
        26: 'OP',
        27: 'TON',
        28: 'DOT',
      };
      for (final e in expected.entries) {
        final pair = SwapPairSdk.tryFromId(e.key);
        expect(pair, isNotNull, reason: 'no pair for id ${e.key}');
        expect(pair!.ticker, e.value);
      }
    });

    test('daemonName is what swapPairFromString accepts', () {
      // The six pairs whose display ticker the daemon does NOT parse. Sending
      // the ticker instead of the daemon name is "Unknown swap pair".
      const divergent = <SwapPairSdk, String>{
        SwapPairSdk.kmd: 'KMD_SPV',
        SwapPairSdk.poly: 'POLYGON',
        SwapPairSdk.robinhood: 'ROBINHOOD',
        SwapPairSdk.unichain: 'UNICHAIN',
        SwapPairSdk.plasma: 'PLASMA',
        SwapPairSdk.pulsex: 'PULSEX',
        SwapPairSdk.monad: 'MONAD',
        SwapPairSdk.optimism: 'OPTIMISM',
      };
      for (final e in divergent.entries) {
        expect(e.key.daemonName, e.value);
      }
      // RHC / UNI / XPL / PLS / MON are rejected by the daemon as-is.
      for (final p in [
        SwapPairSdk.robinhood,
        SwapPairSdk.unichain,
        SwapPairSdk.plasma,
        SwapPairSdk.pulsex,
        SwapPairSdk.monad,
      ]) {
        expect(p.daemonName, isNot(p.ticker));
      }
    });

    test('an unknown id resolves to null, never to another asset', () {
      expect(SwapPairSdk.tryFromId(99), isNull);
      expect(SwapPairSdk.tryFromId(-1), isNull);
    });

    test('tryFromName accepts both the ticker and the daemon name', () {
      expect(SwapPairSdk.tryFromName('op'), SwapPairSdk.optimism);
      expect(SwapPairSdk.tryFromName('OPTIMISM'), SwapPairSdk.optimism);
      expect(SwapPairSdk.tryFromName('nope'), isNull);
    });
  });

  group('SwapInfo pair lookup', () {
    SwapInfo infoFor(int pair, int ctrAmount) => SwapInfo.fromJson({
          'swapId': 'x',
          'state': 0,
          'pair': pair,
          'xfgAmount': 10000000,
          'ctrAmount': ctrAmount,
          'peer': 'host:1',
        });

    test('resolves every daemon pair id to a ticker', () {
      for (final p in SwapPairSdk.values) {
        expect(infoFor(p.id, 0).pairName, p.ticker);
      }
    });

    test('scales counterparty amounts by the pair decimals, not a 7 default',
        () {
      // 1 AVAX = 1e18 wei. The old table stopped at id 11, so AVAX fell back
      // to 7 decimals and rendered 1 AVAX as 100,000,000,000 AVAX.
      final avax = infoFor(SwapPairSdk.avax.id, 1000000000000000000);
      expect(avax.ctrAmountDecimal, closeTo(1.0, 1e-9));

      // Polygon's pairName used to be 'POLYGON', which is not a key in
      // ChainInfo.decimals — another silent 7-decimal fallback.
      final poly = infoFor(SwapPairSdk.poly.id, 1000000000000000000);
      expect(poly.ctrAmountDecimal, closeTo(1.0, 1e-9));

      final btc = infoFor(SwapPairSdk.btc.id, 100000000);
      expect(btc.ctrAmountDecimal, closeTo(1.0, 1e-9));
    });

    test('an unknown pair yields null rather than a wrongly scaled number', () {
      final unknown = infoFor(99, 1000000000000000000);
      expect(unknown.pairName, 'PAIR_99');
      expect(unknown.ctrAmountDecimal, isNull);
      expect(unknown.hasKnownDecimals, isFalse);
    });
  });

  group('ChainInfo', () {
    test('every swapable ticker has decimals, a name and a colour', () {
      for (final t in ChainInfo.swapableChains) {
        expect(ChainInfo.decimals[t], isNotNull, reason: 'decimals for $t');
        expect(ChainInfo.names[t], isNotNull, reason: 'name for $t');
        expect(ChainInfo.colors[t], isNotNull, reason: 'colour for $t');
      }
    });

    test('swapable set is exactly the pairs the daemon registers', () {
      // registerChain(SwapPair::…) in SwapDaemon.cpp — 25 of 29.
      expect(ChainInfo.swapableChains.length, 25);
      for (final staged in ChainInfo.stagedChains) {
        expect(ChainInfo.swapableChains, isNot(contains(staged)),
            reason: '$staged has a staged client and cannot swap');
      }
    });

    test('staged pairs exist in the enum but are not offered', () {
      for (final t in ChainInfo.stagedChains) {
        expect(SwapPairSdk.tryFromName(t), isNotNull);
        expect(ChainInfo.isSwapable(t), isFalse);
      }
    });

    test('tryAmountToDecimal returns null for an unknown ticker', () {
      expect(ChainInfo.tryAmountToDecimal('NOPE', 1), isNull);
      expect(ChainInfo.tryAmountToDecimal('BTC', 100000000), closeTo(1.0, 1e-9));
    });
  });

  group('ChainTypeSdk', () {
    test('covers every swap pair so the chain map can be exhaustive', () {
      // _chainForPair has no `default:` — it previously returned SOL for ten
      // pairs, routing those fills to Solana.
      expect(ChainTypeSdk.values.length, SwapPairSdk.values.length + 1);
    });

    test('an unknown id resolves to null, not to Fuego', () {
      expect(ChainTypeSdk.tryFromId(99), isNull);
    });

    test('isEvm covers the EVM pairs and nothing else', () {
      for (final c in [
        ChainTypeSdk.ethereum,
        ChainTypeSdk.arbitrum,
        ChainTypeSdk.base,
        ChainTypeSdk.bnb,
        ChainTypeSdk.polygon,
        ChainTypeSdk.avax,
        ChainTypeSdk.gleec,
        ChainTypeSdk.robinhood,
        ChainTypeSdk.cro,
        ChainTypeSdk.bob,
        ChainTypeSdk.unichain,
        ChainTypeSdk.plasma,
        ChainTypeSdk.pulsex,
        ChainTypeSdk.monad,
        ChainTypeSdk.optimism,
      ]) {
        expect(c.isEvm, isTrue, reason: '${c.symbol} should be EVM');
      }
      for (final c in [
        ChainTypeSdk.bitcoin,
        ChainTypeSdk.monero,
        ChainTypeSdk.solana,
        ChainTypeSdk.fuego,
        ChainTypeSdk.doge,
      ]) {
        expect(c.isEvm, isFalse, reason: '${c.symbol} is not EVM');
      }
    });

    test('isBtcFamily excludes chains with no verified address prefix', () {
      // DOGE/DASH/ZEC are UTXO but have no P2PKH version bytes wired, so they
      // must not take the signmessage path and produce a Bitcoin address.
      expect(ChainTypeSdk.doge.isBtcFamily, isFalse);
      expect(ChainTypeSdk.dash.isBtcFamily, isFalse);
      expect(ChainTypeSdk.zec.isBtcFamily, isFalse);
      expect(ChainTypeSdk.bitcoin.isBtcFamily, isTrue);
      expect(ChainTypeSdk.litecoin.isBtcFamily, isTrue);
    });
  });

  group('lock type and state no longer coerce', () {
    test('unknown lock type is null, not HTLC', () {
      expect(SwapLockTypeSdk.tryFromId(0), SwapLockTypeSdk.htlc);
      expect(SwapLockTypeSdk.tryFromId(1), SwapLockTypeSdk.ptlc);
      expect(SwapLockTypeSdk.tryFromId(2), SwapLockTypeSdk.bridge);
      expect(SwapLockTypeSdk.tryFromId(7), isNull);
    });

    test('unknown state is null, not open', () {
      expect(SwapStateSdk.tryFromString('completed'), SwapStateSdk.completed);
      expect(SwapStateSdk.tryFromString('refunded_somehow'), isNull);
    });
  });
}
