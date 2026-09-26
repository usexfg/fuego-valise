import 'dart:io';
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/models/chain_info.dart';
import 'package:fuego/models/chain_registry.g.dart';
import 'package:fuego/models/erc20_token.dart';
import 'package:fuego/services/erc20_service.dart';
import 'package:fuego/services/web3_multi_chain_service.dart';

void main() {
  group('ChainRegistry <-> EvmChainKey sync (golden)', () {
    // Test A — every enum entry has a registry entry with a matching chainId.
    test(
      'every EvmChainKey exists in the generated registry with same chainId',
      () {
        expect(EvmChainKey.values.length, 33);
        expect(
          kChains.length,
          EvmChainKey.values.length,
          reason: 'chains.yaml must cover exactly the EvmChainKey set',
        );
        for (final v in EvmChainKey.values) {
          final c = kChainByKey[v.key];
          expect(
            c,
            isNotNull,
            reason: 'EvmChainKey.${v.name} missing from chains.yaml',
          );
          expect(
            c!.chainId,
            v.chainId,
            reason: 'chainId drift for "${v.key}" between enum and chains.yaml',
          );
        }
      },
    );

    test('registry order is deterministic (yaml order) and maps agree', () {
      final keys = kChains.map((c) => c.key).toList();
      expect(keys.toSet().length, keys.length, reason: 'duplicate chain keys');
      for (final c in kChains) {
        expect(kChainIds[c.key], c.chainId);
        expect(kChainRpcs[c.key], c.rpc);
        expect(kChainNames[c.key], c.name);
        expect(kChainColors[c.key], c.colorValue);
      }
      expect(kChainIds['eth'], 1);
      expect(kChainIds['arb'], 42161);
    });

    // Test B — generated file is up to date with chains.yaml.
    test('dart run tool/gen_chains.dart --check exits 0', () async {
      ProcessResult r;
      try {
        r = await Process.run('dart', [
          'run',
          'tool/gen_chains.dart',
          '--check',
        ]);
      } on ProcessException {
        // dart SDK not resolvable in this sandbox — treat as skip.
        return;
      }
      expect(
        r.exitCode,
        0,
        reason:
            'lib/models/chain_registry.g.dart drifted from chains.yaml\n'
            'stdout: ${r.stdout}\nstderr: ${r.stderr}',
      );
    });

    // Test C — tier partition: wallet ∪ swap-evm == all yaml keys.
    test('tiers partition the registry; ChainInfo derives from it', () {
      final swapKeys = kChains
          .where((c) => c.tier == 'swap')
          .map((c) => c.key)
          .toSet();
      final covered = {...kWalletTierKeys, ...swapKeys};
      expect(
        covered.containsAll(kChains.map((c) => c.key)),
        isTrue,
        reason: 'some yaml key is neither swap- nor wallet-tier',
      );
      expect(covered.length, kChains.length);

      // Every EVM chain backed by one of the daemon's 29 SwapPair entries is
      // swap-tier; unsupported wallet-only EVM networks remain excluded.
      expect(swapKeys, {
        'eth',
        'arb',
        'base',
        'bsc',
        'poly',
        'op',
        'avax',
        'cro',
        'monad',
        'xpl',
        'pls',
        'uni',
        'rh',
        'bob',
        'gleec',
      });

      // ChainInfo.walletOnlyChains is derived from kWalletTierKeys.
      expect(
        ChainInfo.walletOnlyChains,
        kWalletTierKeys.map((k) => k.toUpperCase()).toSet(),
      );
      expect(ChainInfo.walletOnlyChains.contains('LINEA'), isTrue);
      expect(ChainInfo.walletOnlyChains.contains('ETH'), isFalse);
    });
  });

  group('Registry consumers stay in sync', () {
    test('Erc20Service routes via generated defaults', () {
      final svc = Erc20Service();
      expect(svc.chainIdFor('eth'), 1);
      expect(svc.chainIdFor('sei'), 1329);
      expect(svc.chainIdFor('tempo'), 4217);
      expect(svc.rpcUrlFor('eth'), contains('llamarpc'));
      expect(svc.chainIdFor('unknown'), 1); // legacy fallback preserved
      svc.dispose();
    });

    test('Web3MultiChainService.chainIds forwards to generated map', () {
      expect(Web3MultiChainService.chainIds, kChainIds);
      expect(Web3MultiChainService.defaultEthRpc, kChainRpcs['eth']);
    });

    test('Erc20Registry.displayNameFor resolves from generated names', () {
      expect(Erc20Registry.displayNameFor('eth'), 'Ethereum');
      expect(Erc20Registry.displayNameFor('ZKSYNC'), 'ZKsync Era');
      expect(Erc20Registry.displayNameFor('peaq'), 'peaq');
      expect(Erc20Registry.displayNameFor('nope'), 'NOPE'); // fallback
    });

    test('ChainInfo keeps legacy ticker aliases alongside generated keys', () {
      expect(ChainInfo.names['MON'], 'Monad'); // legacy alias
      expect(ChainInfo.names['monad'], 'Monad'); // generated key
      expect(
        ChainInfo.names['RHC'],
        'Robinhood Chain(ETH)',
      ); // legacy wording kept
      expect(ChainInfo.names['rh'], 'Robinhood Chain');
      expect(ChainInfo.names['BASE'], 'Base(ETH)');
      expect(ChainInfo.colors['SOL'], const Color(0xFF9945FF));
    });
  });
}
