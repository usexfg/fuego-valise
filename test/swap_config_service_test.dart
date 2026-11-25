import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/services/swap_config_service.dart';
import 'package:solana/base58.dart' as solana_base58;

const _privateKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _registry = '0x1111111111111111111111111111111111111111';

void main() {
  group('SwapConfigService.buildConfig', () {
    test('emits a catalog-bound mainnet EVM deployment', () {
      final config = SwapConfigService.buildConfig(
        chains: const {
          'eth': SwapChainConfig(
            wif: _privateKey,
            rpcUrl: 'http://127.0.0.1:8545',
            chainId: 1,
            htlcRegistry: _registry,
          ),
        },
        network: 'mainnet',
      );

      final chains = config['evm_chains'] as Map<String, dynamic>;
      final eth = chains['eth'] as Map<String, dynamic>;
      expect(config['network'], 'mainnet');
      expect(eth['rpc_url'], 'http://127.0.0.1:8545');
      expect(eth['chain_id'], 1);
      expect(eth['htlc_registry'], _registry);
      expect(eth['private_key'], _privateKey);
      expect(eth['address'], startsWith('0x'));
    });

    test('requires an explicit testnet EVM chain ID', () {
      final config = SwapConfigService.buildConfig(
        chains: const {
          'eth': SwapChainConfig(
            wif: _privateKey,
            rpcUrl: 'http://127.0.0.1:8545',
            chainId: 11155111,
            htlcRegistry: _registry,
          ),
        },
        network: 'testnet',
      );

      final chains = config['evm_chains'] as Map<String, dynamic>;
      expect((chains['eth'] as Map<String, dynamic>)['chain_id'], 11155111);
    });

    test('rejects incomplete or non-EVM testnet configurations', () {
      expect(
        () => SwapConfigService.buildConfig(
          chains: const {
            'eth': SwapChainConfig(
              wif: _privateKey,
              rpcUrl: 'http://127.0.0.1:8545',
              htlcRegistry: _registry,
            ),
          },
          network: 'testnet',
        ),
        throwsArgumentError,
      );
      expect(
        () => SwapConfigService.buildConfig(
          chains: const {'btc': SwapChainConfig(wif: _privateKey)},
          network: 'testnet',
        ),
        throwsArgumentError,
      );
    });

    test('serializes Solana deployment and keypair fields', () {
      final solProgramId = solana_base58.base58encode(List<int>.filled(32, 1));
      final solKeypair = solana_base58.base58encode(
        List<int>.generate(64, (index) => index + 1),
      );
      final config = SwapConfigService.buildConfig(
        chains: {
          'sol': SwapChainConfig(
            wif: solKeypair,
            rpcUrl: 'http://127.0.0.1:8899',
            solProgramId: solProgramId,
          ),
        },
        network: 'mainnet',
      );

      expect(config['sol_rpc_host'], '127.0.0.1');
      expect(config['sol_rpc_port'], 8899);
      expect(config['sol_program_id'], solProgramId);
      expect(config['sol_keypair'], solKeypair);
    });

    test('rejects nonlocal Solana RPC endpoints', () {
      final solProgramId = solana_base58.base58encode(List<int>.filled(32, 1));
      final solKeypair = solana_base58.base58encode(
        List<int>.generate(64, (index) => index + 1),
      );

      expect(
        () => SwapConfigService.buildConfig(
          chains: {
            'sol': SwapChainConfig(
              wif: solKeypair,
              rpcUrl: 'https://api.mainnet-beta.solana.com',
              solProgramId: solProgramId,
            ),
          },
          network: 'mainnet',
        ),
        throwsArgumentError,
      );
    });

    test('rejects Base58 Solana values with the wrong decoded length', () {
      final shortProgramId = solana_base58.base58encode(
        List<int>.filled(31, 1),
      );
      final shortKeypair = solana_base58.base58encode(List<int>.filled(63, 1));

      expect(
        () => SwapConfigService.buildConfig(
          chains: {
            'sol': SwapChainConfig(
              wif: shortKeypair,
              rpcUrl: 'http://127.0.0.1:8899',
              solProgramId: shortProgramId,
            ),
          },
          network: 'mainnet',
        ),
        throwsArgumentError,
      );
    });

    test('rejects a mainnet EVM chain ID outside the catalog', () {
      expect(
        () => SwapConfigService.buildConfig(
          chains: const {
            'eth': SwapChainConfig(
              wif: _privateKey,
              rpcUrl: 'http://127.0.0.1:8545',
              chainId: 2,
              htlcRegistry: _registry,
            ),
          },
          network: 'mainnet',
        ),
        throwsArgumentError,
      );
    });

    test('serializes Monero daemon and wallet credentials', () {
      final config = SwapConfigService.buildConfig(
        chains: const {
          'xmr': SwapChainConfig(
            wif: _privateKey,
            xmrViewKey: _privateKey,
            xmrDaemonHost: '127.0.0.1',
            xmrWalletHost: '127.0.0.1',
          ),
        },
        network: 'mainnet',
      );

      expect(config['xmr_daemon_host'], '127.0.0.1');
      expect(config['xmr_wallet_host'], '127.0.0.1');
      expect(config['xmr_spend_key'], _privateKey);
      expect(config['xmr_view_key'], _privateKey);
    });

    test('rejects invalid XFG secret keys', () {
      expect(
        () => SwapConfigService.buildConfig(
          chains: const {
            'op': SwapChainConfig(
              wif: _privateKey,
              rpcUrl: 'http://127.0.0.1:8545',
              chainId: 10,
              htlcRegistry: _registry,
            ),
          },
          network: 'mainnet',
          xfgSecretKey: 'not-a-secret-key',
        ),
        throwsArgumentError,
      );
    });
  });

  group('SwapConfigService.stripSecrets', () {
    test('persisted config has no raw private keys', () {
      final full = SwapConfigService.buildConfig(
        chains: const {
          'eth': SwapChainConfig(
            wif: _privateKey,
            rpcUrl: 'http://127.0.0.1:8545',
            chainId: 1,
            htlcRegistry: _registry,
          ),
        },
        network: 'mainnet',
        xfgSecretKey: _privateKey,
      );
      full['btc_wif'] = '5fakewif';
      full['sol_keypair'] = 'base58keypair';
      final stripped = SwapConfigService.stripSecrets(full);
      final encoded = stripped.toString();
      expect(stripped.containsKey('xfg_secret_key'), isFalse);
      expect(stripped.containsKey('btc_wif'), isFalse);
      expect(stripped.containsKey('sol_keypair'), isFalse);
      final eth = (stripped['evm_chains'] as Map)['eth'] as Map;
      expect(eth.containsKey('private_key'), isFalse);
      expect(eth['rpc_url'], 'http://127.0.0.1:8545');
      expect(eth['address'], startsWith('0x'));
      expect(encoded.contains(_privateKey), isFalse);
    });
  });
}
