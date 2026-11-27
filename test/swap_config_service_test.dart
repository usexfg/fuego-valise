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

  group('Bitcoin-family chains', () {
    const btcWif = 'KwntMbt59tTsj8xqpqYqRRWufyjGunvhSyeMo3NTYpFYzZbXJ5Hp';
    const ltcWif = 'T3d9oMBFZGSUVybiNUVhdn4HcqNayswbGBYcer117nRiWT8Gph6i';
    final btcDefaults = SwapConfigService.utxoSpvDefaults['btc']!;

    Map<String, dynamic> build(String chain, SwapChainConfig cfg) =>
        SwapConfigService.buildConfig(chains: {chain: cfg}, network: 'mainnet');

    test('a local full node serves Alice and Bob', () {
      final config = build(
        'btc',
        const SwapChainConfig(
          wif: btcWif,
          rpcUrl: 'http://127.0.0.1:8332',
          rpcUser: 'swap',
          rpcPassword: 'secret',
        ),
      );
      expect(config['btc_rpc_host'], '127.0.0.1');
      expect(config['btc_rpc_port'], 8332);
      expect(config['btc_rpc_user'], 'swap');
      expect(config['btc_rpc_pass'], 'secret');
      expect(config['btc_network'], 'main');
      expect(config['btc_wif'], btcWif);
      expect(config.containsKey('btc_mode'), isFalse);
    });

    test('a full node RPC must be local and authenticated', () {
      expect(
        () => build(
          'btc',
          const SwapChainConfig(
            wif: btcWif,
            rpcUrl: 'http://192.168.1.5:8332',
            rpcUser: 'swap',
            rpcPassword: 'secret',
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => build(
          'btc',
          const SwapChainConfig(wif: btcWif, rpcUrl: 'http://127.0.0.1:8332'),
        ),
        throwsArgumentError,
      );
    });

    test('SPV writes three servers, a quorum of two and a checkpoint', () {
      final config = build(
        'ltc',
        SwapChainConfig(
          wif: ltcWif,
          servers: SwapConfigService.utxoSpvDefaults['ltc']!.servers,
          checkpointHeight:
              SwapConfigService.utxoSpvDefaults['ltc']!.checkpointHeight,
          checkpointHash:
              SwapConfigService.utxoSpvDefaults['ltc']!.checkpointHash,
        ),
      );
      expect(config['ltc_mode'], 'spv');
      expect(config['ltc_spv_server_2'], 'backup.electrum-ltc.org:443');
      expect(config['ltc_spv_min_servers'], 2);
      expect(config['ltc_spv_checkpoint_height'], 2772730);
      expect(config.containsKey('ltc_rpc_host'), isFalse);
    });

    test('SPV the daemon would never trust is refused', () {
      SwapChainConfig spv({
        List<String>? servers,
        int? quorum,
        int? height,
        String? hash,
      }) => SwapChainConfig(
        wif: btcWif,
        servers: servers ?? btcDefaults.servers,
        minServers: quorum,
        checkpointHeight: height ?? btcDefaults.checkpointHeight,
        checkpointHash: hash ?? btcDefaults.checkpointHash,
      );
      expect(
        () => build('btc', spv(servers: ['electrum.blockstream.info:50002'])),
        throwsArgumentError,
      );
      expect(
        () => build(
          'btc',
          spv(servers: ['a.example:1', 'a.example:2', 'ssl://A.example:3']),
        ),
        throwsArgumentError,
      );
      expect(() => build('btc', spv(quorum: 1)), throwsArgumentError);
      expect(() => build('btc', spv(height: 0)), throwsArgumentError);
      expect(() => build('btc', spv(hash: 'abc')), throwsArgumentError);
    });

    test('KMD, DCR and chains without a transport are refused', () {
      for (final chain in ['kmd', 'dcr', 'doge']) {
        expect(
          () => build(chain, SwapChainConfig(wif: btcWif, servers: const [])),
          throwsArgumentError,
        );
      }
    });

    test('only compressed-key WIFs are accepted', () {
      expect(SwapConfigService.validateWif(btcWif, 'btc'), isNull);
      expect(SwapConfigService.validateWif(btcWif, 'bch'), isNull);
      expect(SwapConfigService.validateWif(ltcWif, 'ltc'), isNull);
      expect(
        SwapConfigService.validateWif(
          '5HueCGU8rMjxEXxiPuD5BDku4MkFqeZyd4dZ1jvhTVqvbTLvyTJ',
          'btc',
        ),
        isNotNull,
      );
      expect(SwapConfigService.validateWif(btcWif, 'ltc'), isNotNull);
      expect(SwapConfigService.validateWif(btcWif, 'kmd'), isNotNull);
    });

    test('Electrum server hosts are compared without scheme or port', () {
      expect(
        SwapConfigService.electrumServerHost('ssl://Electrum.Example:50002'),
        'electrum.example',
      );
      expect(SwapConfigService.electrumServerHost('no-port'), '');
    });
  });

  group('SwapConfigService.parseGeneratedConfig', () {
    test('reads the generator output despite its comments', () {
      const output = '''
Generating...
{
  // ── BTC ──
  "btc_mode": "spv",
  "btc_spv_server_0": "electrum.blockstream.info:50002",
  "note": "https://kept//inside",
  "btc_wif": "KwntMbt59tTsj8xqpqYqRRWufyjGunvhSyeMo3NTYpFYzZbXJ5Hp",  // P2PKH address: 1abc
  "evm_chains": {}
}
''';
      final config = SwapConfigService.parseGeneratedConfig(output);
      expect(config['btc_mode'], 'spv');
      expect(config['note'], 'https://kept//inside');
      expect(
        config['btc_wif'],
        'KwntMbt59tTsj8xqpqYqRRWufyjGunvhSyeMo3NTYpFYzZbXJ5Hp',
      );
    });

    test('refuses output without a configuration object', () {
      expect(
        () => SwapConfigService.parseGeneratedConfig('error'),
        throwsFormatException,
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
