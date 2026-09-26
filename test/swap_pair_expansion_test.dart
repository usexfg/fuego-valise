import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/chain_info.dart';
import 'package:fuego/models/swap_models.dart';

void main() {
  group('daemon-backed EVM swap pairs', () {
    test('use the exact C++ SwapPair IDs and wallet tickers', () {
      final expected = <SwapPairSdk, (int, String)>{
        SwapPairSdk.gleec: (12, 'GLEEC'),
        SwapPairSdk.robinhood: (13, 'RHC'),
        SwapPairSdk.avax: (14, 'AVAX'),
        SwapPairSdk.cro: (15, 'CRO'),
        SwapPairSdk.bob: (16, 'BOB'),
        SwapPairSdk.unichain: (18, 'UNI'),
        SwapPairSdk.plasma: (19, 'XPL'),
        SwapPairSdk.pulsex: (23, 'PLS'),
        SwapPairSdk.monad: (25, 'MON'),
        SwapPairSdk.optimism: (26, 'OP'),
      };

      for (final entry in expected.entries) {
        expect(entry.key.id, entry.value.$1);
        expect(entry.key.ticker, entry.value.$2);
        expect(SwapPairSdk.fromId(entry.value.$1), entry.key);
      }
    });

    test('matching chain types are append-only EVM variants', () {
      final expected = <ChainTypeSdk, int>{
        ChainTypeSdk.avax: 13,
        ChainTypeSdk.gleec: 14,
        ChainTypeSdk.robinhood: 15,
        ChainTypeSdk.cro: 16,
        ChainTypeSdk.bob: 17,
        ChainTypeSdk.unichain: 18,
        ChainTypeSdk.plasma: 19,
        ChainTypeSdk.pulsex: 20,
        ChainTypeSdk.monad: 21,
        ChainTypeSdk.optimism: 22,
      };

      for (final entry in expected.entries) {
        expect(entry.key.id, entry.value);
        expect(entry.key.isEvm, isTrue);
        expect(ChainTypeSdk.fromId(entry.value), entry.key);
      }
    });

    test('new wallet tickers expose live EVM swap metadata', () {
      const tickers = {
        'GLEEC',
        'RHC',
        'AVAX',
        'CRO',
        'BOB',
        'UNI',
        'XPL',
        'PLS',
        'MON',
        'OP',
      };

      expect(ChainInfo.swapableChains, containsAll(tickers));
      for (final ticker in tickers) {
        expect(ChainInfo.info[ticker]?['wired'], isNot('false'));
        expect(ChainInfo.info[ticker]?['htlc'], 'HashedTimelock.sol');
        expect(ChainInfo.ptlc[ticker], contains('BRIDGE'));
        expect(ChainInfo.decimals[ticker], 18);
      }
    });
  });
}
