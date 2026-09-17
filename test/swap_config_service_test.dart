import 'package:flutter_test/flutter_test.dart';
import 'package:fuego/services/swap_config_service.dart';

const _privateKey =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

void main() {
  group('SwapConfigService.buildConfig', () {
    test('translates Plasma wallet key to daemon prefix', () {
      final config = SwapConfigService.buildConfig(
        chains: const {
          'xpl': SwapChainConfig(
            wif: _privateKey,
            rpcUrl: 'https://plasma.example:8545',
          ),
        },
      );

      expect(config['plasma_mode'], 'rpc');
      expect(config['plasma_priv_key'], _privateKey);
      expect(config['plasma_rpc_host'], 'plasma.example');
      expect(config['plasma_rpc_port'], 8545);
      expect(config['plasma_chain_id'], 9745);
      expect(config, isNot(contains('xpl_priv_key')));
    });

    test('translates PulseChain wallet key to daemon prefix', () {
      final config = SwapConfigService.buildConfig(
        chains: const {
          'pls': SwapChainConfig(
            wif: _privateKey,
            rpcUrl: 'https://pulse.example:8545',
          ),
        },
      );

      expect(config['pulsex_mode'], 'rpc');
      expect(config['pulsex_priv_key'], _privateKey);
      expect(config['pulsex_rpc_host'], 'pulse.example');
      expect(config['pulsex_rpc_port'], 8545);
      expect(config['pulsex_chain_id'], 369);
      expect(config, isNot(contains('pls_priv_key')));
    });

    test('uses generated Monad mainnet chain ID', () {
      final config = SwapConfigService.buildConfig(
        chains: const {
          'monad': SwapChainConfig(
            wif: _privateKey,
            rpcUrl: 'https://monad.example:8545',
          ),
        },
      );

      expect(config['monad_chain_id'], 143);
      expect(config['monad_chain_id'], isNot(185));
    });

    test('keeps daemon-native prefixes and includes metadata chain ID', () {
      final config = SwapConfigService.buildConfig(
        chains: const {
          'op': SwapChainConfig(
            wif: _privateKey,
            rpcUrl: 'https://optimism.example:8545',
          ),
        },
        xfgSecretKey: 'xfg-secret',
      );

      expect(config['op_mode'], 'rpc');
      expect(config['op_priv_key'], _privateKey);
      expect(config['op_chain_id'], 10);
      expect(config['xfg_secret_key'], 'xfg-secret');
    });
  });
}
