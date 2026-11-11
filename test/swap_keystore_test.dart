import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/services/swap_config_service.dart';
import 'package:fuego/services/swap_keystore.dart';

const _privateKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const _xfgSecret =
    'fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
const _btcWif = 'KwntMbt59tTsj8xqpqYqRRWufyjGunvhSyeMo3NTYpFYzZbXJ5Hp';

Map<String, dynamic> _fullConfig({String rpcPassword = 'n0de-pass'}) =>
    SwapConfigService.buildConfig(
      chains: {
        'eth': const SwapChainConfig(
          wif: _privateKey,
          rpcUrl: 'http://127.0.0.1:8545',
          chainId: 1,
          htlcRegistry: '0x1111111111111111111111111111111111111111',
        ),
        'btc': SwapChainConfig(
          wif: _btcWif,
          rpcUrl: 'http://127.0.0.1:8332',
          rpcUser: 'swap',
          rpcPassword: rpcPassword,
        ),
      },
      network: 'mainnet',
      xfgSecretKey: _xfgSecret,
    );

void main() {
  group('SwapKeystore.seal', () {
    test('every secret becomes a keystore reference', () {
      final sealed = SwapKeystore.seal(_fullConfig());
      final config = sealed.config;
      final eth =
          (config['evm_chains'] as Map<String, dynamic>)['eth']
              as Map<String, dynamic>;

      expect(config['btc_wif'], 'keystore:btc_wif');
      expect(config['btc_rpc_pass'], 'keystore:btc_rpc_pass');
      expect(config['xfg_secret_key'], 'keystore:xfg_secret_key');
      expect(eth['private_key'], 'keystore:evm_eth_private_key');
      expect(sealed.secrets, {
        'btc_wif': _btcWif,
        'btc_rpc_pass': 'n0de-pass',
        'xfg_secret_key': _xfgSecret,
        'evm_eth_private_key': _privateKey,
      });
    });

    test('public settings stay in the configuration', () {
      final config = SwapKeystore.seal(_fullConfig()).config;
      final eth =
          (config['evm_chains'] as Map<String, dynamic>)['eth']
              as Map<String, dynamic>;
      expect(config['btc_rpc_user'], 'swap');
      expect(config['btc_rpc_port'], 8332);
      expect(eth['address'], startsWith('0x'));
      expect(eth['chain_id'], 1);
    });

    test('no secret value reaches the written configuration', () {
      final text = jsonEncode(SwapKeystore.seal(_fullConfig()).config);
      for (final secret in [_privateKey, _xfgSecret, _btcWif, 'n0de-pass']) {
        expect(text.contains(secret), isFalse, reason: secret);
      }
    });

    test('a secret the daemon cannot substitute is refused', () {
      for (final password in ['has space', 'has"quote', r'has\backslash']) {
        expect(
          () => SwapKeystore.seal(_fullConfig(rpcPassword: password)),
          throwsArgumentError,
          reason: password,
        );
      }
    });

    test('the daemon secret charset is printable ASCII without quotes', () {
      expect(SwapKeystore.isPlainSecret('abc-_~!'), isTrue);
      expect(SwapKeystore.isPlainSecret(''), isFalse);
      expect(SwapKeystore.isPlainSecret('tab\there'), isFalse);
      expect(SwapKeystore.isPlainSecret('é'), isFalse);
    });
  });
}
