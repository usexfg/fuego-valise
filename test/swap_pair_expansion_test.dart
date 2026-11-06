import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/chain_info.dart';
import 'package:fuego/models/chain_registry.g.dart';
import 'package:fuego/models/swap_models.dart';
import 'package:fuego/services/swap_daemon_client.dart';

void main() {
  group('generic-adapter EVM swap pairs (catalog ids 29-45)', () {
    const catalog = <int, (SwapPairSdk, ChainTypeSdk, String, String)>{
      29: (SwapPairSdk.linea, ChainTypeSdk.linea, 'LINEA', 'linea'),
      30: (SwapPairSdk.zksync, ChainTypeSdk.zksync, 'ZKS', 'zksync'),
      31: (SwapPairSdk.hyperevm, ChainTypeSdk.hyperevm, 'HYPER', 'hyperevm'),
      32: (SwapPairSdk.ink, ChainTypeSdk.ink, 'INK', 'ink'),
      33: (SwapPairSdk.rsk, ChainTypeSdk.rsk, 'RSK', 'rsk'),
      34: (SwapPairSdk.gnosis, ChainTypeSdk.gnosis, 'GNO', 'gnosis'),
      35: (SwapPairSdk.flare, ChainTypeSdk.flare, 'FLR', 'flare'),
      36: (SwapPairSdk.kaia, ChainTypeSdk.kaia, 'KAIA', 'kaia'),
      37: (SwapPairSdk.scroll, ChainTypeSdk.scroll, 'SCR', 'scroll'),
      38: (SwapPairSdk.abstract, ChainTypeSdk.abstract, 'ABS', 'abstract'),
      39: (SwapPairSdk.plume, ChainTypeSdk.plume, 'PLUME', 'plume'),
      40: (SwapPairSdk.soneium, ChainTypeSdk.soneium, 'SONEIUM', 'soneium'),
      41: (SwapPairSdk.doma, ChainTypeSdk.doma, 'DOMA', 'doma'),
      42: (SwapPairSdk.beam, ChainTypeSdk.beam, 'BEAM', 'beam'),
      43: (SwapPairSdk.moonriver, ChainTypeSdk.moonriver, 'MOVR', 'moonriver'),
      44: (SwapPairSdk.peaq, ChainTypeSdk.peaq, 'PEAQ', 'peaq'),
      45: (SwapPairSdk.sei, ChainTypeSdk.sei, 'SEI', 'sei'),
    };

    test('wire ids, tickers and chain types match the suite catalog', () {
      for (final MapEntry(key: id, value: (pair, chain, ticker, key))
          in catalog.entries) {
        expect(pair.id, id);
        expect(pair.ticker, ticker);
        expect(pair.chain, chain);
        expect(chain.isEvm, isTrue);
        expect(chain.evm?.key, key);
        expect(SwapPairSdk.tryFromId(id), pair);
      }
    });

    test('each is swap tier in chains.yaml with the catalog chain id', () {
      for (final (pair, _, ticker, key) in catalog.values) {
        final entry = kChainByKey[key]!;
        expect(entry.tier, 'swap', reason: '$key is not swap tier');
        expect(entry.ticker, ticker);
        expect(pair.chain.evm!.chainId, entry.chainId);
      }
    });

    test('each exposes HashedTimelock swap metadata', () {
      for (final (_, _, ticker, _) in catalog.values) {
        expect(ChainInfo.swapableChains, contains(ticker));
        expect(ChainInfo.walletOnlyChains, isNot(contains(ticker)));
        expect(ChainInfo.info[ticker]?['htlc'], 'HashedTimelock.sol');
        expect(ChainInfo.ptlc[ticker], contains('BRIDGE'));
        expect(ChainInfo.decimals[ticker], 18);
        expect(ChainInfo.desc[ticker], isNotNull);
      }
    });

    test('PEAQ discloses that xfg-swapd refuses it without a price feed', () {
      expect(ChainInfo.info['PEAQ']?['user'], contains('price feed'));
    });
  });

  group('chains.yaml swap tier and SwapPairSdk agree', () {
    test('every EVM pair is swap tier and every swap-tier chain has a pair', () {
      final pairKeys = {
        for (final p in SwapPairSdk.values)
          if (p.chain.evm != null) p.chain.evm!.key,
      };
      final swapTierKeys = {
        for (final c in kChains)
          if (c.tier == 'swap') c.key,
      };
      expect(pairKeys, swapTierKeys);
    });

    test('Tempo stays wallet tier: it has no native coin to escrow', () {
      expect(kChainByKey['tempo']!.tier, 'wallet');
      expect(kChainByKey['tempo']!.gasToken, isEmpty);
      expect(ChainInfo.walletOnlyChains, {'TEMPO'});
    });
  });

  group('SwapChain.pairTicker', () {
    SwapChain chain(int id, String symbol, String asset) => SwapChain(
      id: id,
      key: '',
      symbol: symbol,
      assetTicker: asset,
      name: '',
      family: 'evm',
      decimals: 18,
      implementation: '',
      protocol: true,
      configured: true,
      ready: true,
      readinessError: '',
    );

    test('distinguishes chains that settle in the same asset', () {
      final ids = [1, 4, 5, 13, 16, 18, 26, 29, 30, 32, 37, 38, 40, 41];
      final tickers = {for (final id in ids) chain(id, 'X', 'ETH').pairTicker};
      expect(tickers.length, ids.length);
      expect(chain(30, 'ZKSYNC', 'ETH').ticker, 'ETH');
      expect(chain(30, 'ZKSYNC', 'ETH').pairTicker, 'ZKS');
    });

    test('falls back to the daemon symbol for an id the wallet lacks', () {
      expect(chain(17, 'SIA', 'SC').pairTicker, 'SIA');
    });
  });

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
